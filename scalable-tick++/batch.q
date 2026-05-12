// Batch loader - loads files (CSV, TXT, parquet) into HDB as date-partitioned splayed tables
// Standalone one-shot process - exits after load completes
//
// Usage: q kdb-x-platform/batch.q -file <path> -table <name> -date <YYYY.MM.DD> [opts] -procName BATCH
//   -file      Path to data file
//   -table     Target table name (must match a schema in SCHEMA_DIR)
//   -date      Partition date (YYYY.MM.DD)
//   -delimiter Delimiter character (default: comma)
//   -sym       Default sym value if sym column not in source data
//   -hdbDir    HDB directory path
//   -schemaDir Schema directory path
//   -mode      Write mode: append (default) or overwrite
//   -origFile  Original filename (for extension detection, e.g. when .gz was stripped)
//   -colMap    Column rename mapping: "SrcCol:tgtCol,SrcCol2:tgtCol2"
//   -stream    If "1", use sequential read (.Q.fs) instead of .Q.fsn (for FIFO pipes)

// Bootstrap
system"l utils/main.q";

.log.info["Initialising batch loader"];

// ── CLI args ────────────────────────────────────────────────────────────

FILE:first CLI_ARGS[`file];
TABLE:`$first CLI_ARGS[`table];
DATE:"D"$first CLI_ARGS[`date];
DELIMITER:first first CLI_ARGS[`delimiter],enlist ",";
SYM_VAL:$[`sym in key CLI_ARGS; `$first CLI_ARGS[`sym]; `];
HDB_DIR:hsym `$first CLI_ARGS[`hdbDir];
SCHEMA_DIR:first CLI_ARGS[`schemaDir];
MODE:$[`mode in key CLI_ARGS; `$first CLI_ARGS[`mode]; `append];
ORIG_FILE:$[`origFile in key CLI_ARGS; first CLI_ARGS[`origFile]; FILE];
STREAM:`stream in key CLI_ARGS;

// Column rename mapping: "SrcCol:tgtCol,SrcCol2:tgtCol2" -> list of (src;tgt) symbol pairs
COL_MAP:$[`colMap in key CLI_ARGS;
    {`$":" vs x} each "," vs first CLI_ARGS[`colMap];
    ()
 ];

// Chunk threshold (10MB)
CHUNK_THRESHOLD:10*1024*1024;

// ── Validation ──────────────────────────────────────────────────────────

if[null DATE;
    .log.error["Invalid date format. Use YYYY.MM.DD, got: ",first CLI_ARGS[`date]];
    exit 1
 ];

if[not MODE in `append`overwrite;
    .log.error["Invalid mode '",string[MODE],"'. Must be append or overwrite"];
    exit 1
 ];

if[()~key hsym `$FILE;
    .log.error["File not found: ",FILE];
    exit 1
 ];

// ── Schema loading ──────────────────────────────────────────────────────

.log.info["Loading schemas from ",SCHEMA_DIR];
{system each "l ",/:1_/:string .Q.dd[sDir;] each key sDir:hsym `$x}[SCHEMA_DIR];

if[not TABLE in tables[];
    .log.error["Table '",string[TABLE],"' not found in schemas. Available: ",", " sv string tables[]];
    exit 1
 ];

SCHEMA:meta TABLE;
schemaCols:exec c from SCHEMA;
schemaTypes:exec t from SCHEMA;

.log.info[("Batch load | table=[%s] date=[%s] cols=[%s] types=[%s]";string TABLE;string DATE;", " sv string schemaCols;schemaTypes)];

// ── Type mapping ────────────────────────────────────────────────────────

// Map kdb type chars (from meta) to 0: reader format chars.
// Lowercase keys = atomic/simple column types (one value per cell).
//   Added: g → G (guid).
// Uppercase keys = nested list columns (one list per cell), e.g. column of strings.
//   Added: C → * (read as raw char-vector per field, for explicit nested-char schemas).
// Space key = general-list column (meta type for `col:()`), e.g. `message:()` for a
//   column of strings. Also mapped to * so each field is kept as a char vector.
TYPE_MAP:("nsdjihefcbxpztmgC "!"NSDJIHEFCBXPZTMG**");

// Build type string for source columns based on schema
// Source columns not in schema get "*" (read as string, dropped later)
.batch.buildSrcTypeStr:{[srcCols]
    schemaDict:schemaCols!schemaTypes;
    {$[x in key y; TYPE_MAP y x; "*"]}[;schemaDict] each srcCols
 };

// ── File type detection ─────────────────────────────────────────────────

origName:ORIG_FILE;
if[origName like "*.gz"; origName:-3_origName];
if[origName like "*.zip"; origName:-4_origName];
if[origName like "*.zst"; origName:-4_origName];

FILE_TYPE:$[
    origName like "*.csv";     `csv;
    origName like "*.txt";     `txt;
    origName like "*.parquet"; `parquet;
    origName like "*.pq";      `parquet;
    `unknown
 ];

if[FILE_TYPE=`unknown;
    .log.error["Cannot determine file type from: ",ORIG_FILE,". Supported: .csv, .txt, .parquet, .pq"];
    exit 1
 ];

.log.info[("Detected file type: %s";string FILE_TYPE)];

// ── Column mapping helper ───────────────────────────────────────────────

// Apply column rename mapping to a table
// COL_MAP is a list of (srcName;tgtName) symbol pairs
.batch.applyColMap:{[data]
    if[0=count COL_MAP; :data];
    c:cols data;
    {[c;m] @[c; c?first m; :; last m]}/[c; COL_MAP] xcol data
 };

// ── Save to HDB ─────────────────────────────────────────────────────────

.batch.totalRows:0;

.batch.partPath:{` sv HDB_DIR,(`$string DATE),TABLE};

.batch.saveToHDB:{[data]
    // Enumerate symbol columns against HDB sym file
    data:.Q.en[HDB_DIR; data];
    // Trailing ` on path ensures kdb writes splayed (directory per column) not serialized (single file)
    splayPath:` sv .batch.partPath[],`;
    splayPath upsert data;
    .batch.totalRows+:count data;
    .log.info[("Saved %d rows (total: %d)";count data;.batch.totalRows)];
 };

// ── Process chunk (transform + save) ────────────────────────────────────

.batch.processChunk:{[data]
    // Apply column renaming
    data:.batch.applyColMap[data];
    // Add time column if not in source
    if[not `time in cols data;
        data:update time:.z.n from data
    ];
    // Add sym column if not in source
    if[not `sym in cols data;
        if[null SYM_VAL;
            .log.error["Source data has no 'sym' column and no -sym arg provided"];
            exit 1
        ];
        data:update sym:SYM_VAL from data
    ];
    // Reorder to match schema, keep only schema columns
    data:schemaCols xcols data;
    data:schemaCols#data;
    // Save
    .batch.saveToHDB[data];
 };

// ── Readers ─────────────────────────────────────────────────────────────

// Read header line and return source column names
.batch.readHeader:{[fp;delim]
    `$delim vs first read0 `$fp
 };

// Full single-pass delimited read
.batch.readFull:{[fp;delim;typeStr]
    .log.info["Reading file (single pass)"];
    (typeStr; enlist delim) 0: `$fp
 };

// Chunked delimited read using .Q.fsn (seekable files)
.batch.readChunked:{[fp;delim;typeStr;hdrLine;chunkSize]
    .log.info[("Reading file (chunked, %d byte chunks)";chunkSize)];
    .batch.chunkNum:0;
    .Q.fsn[
        {[delim;typeStr;hdrLine;lines]
            // First chunk: first line is the header, skip it
            if[0=.batch.chunkNum; lines:1_lines];
            .batch.chunkNum+:1;
            if[0=count lines; :()];
            // Prepend header so 0: can parse columns
            data:(typeStr; enlist delim) 0: (enlist hdrLine),lines;
            .log.info[("Chunk %d: %d rows";.batch.chunkNum;count data)];
            .batch.processChunk[data];
        }[delim;typeStr;hdrLine];
        `$fp;
        chunkSize
    ];
 };

// Chunked sequential read using .Q.fs (for FIFO pipes / non-seekable streams)
.batch.readStream:{[fp;delim;typeStr;hdrLine]
    .log.info["Reading file (streaming / sequential)"];
    .batch.chunkNum:0;
    .Q.fs[
        {[delim;typeStr;hdrLine;lines]
            if[0=.batch.chunkNum; lines:1_lines];
            .batch.chunkNum+:1;
            if[0=count lines; :()];
            data:(typeStr; enlist delim) 0: (enlist hdrLine),lines;
            .batch.processChunk[data];
        }[delim;typeStr;hdrLine];
        `$fp
    ];
 };

// Parquet reader
.batch.readParquet:{[fp]
    .log.info["Reading parquet file"];
    @[.pq.read; hsym `$fp; {.log.error["Parquet read failed: ",x]; exit 1}]
 };

// ── Main ────────────────────────────────────────────────────────────────

.log.info[("Batch load starting | file=[%s] table=[%s] date=[%s] mode=[%s]";
    ORIG_FILE; string TABLE; string DATE; string MODE)];

// Clear existing partition if overwrite mode OR if it's an empty stub (from .Q.chk)
partStr:1_string .batch.partPath[];
if[not ()~key .batch.partPath[];
    clearPart:{[p] .log.info["Clearing partition at ",p]; system "rm -rf ",p};
    $[MODE=`overwrite;
        clearPart partStr;
      // Empty stub from .Q.chk: first column has 0 rows
      0=count get ` sv .batch.partPath[],first schemaCols;
        clearPart partStr;
      // Non-empty partition in append mode — keep it
      (::)
    ];
 ];

$[FILE_TYPE in `csv`txt;
    [
        fileSize:hcount `$FILE;
        .log.info[("File size: %d bytes (%d MB)";fileSize;`long$fileSize%1024*1024)];

        // Read header to discover source columns
        hdrLine:first read0 `$FILE;
        srcCols:`$DELIMITER vs hdrLine;

        // Apply column mapping to header names for type lookup
        mappedCols:srcCols;
        if[count COL_MAP;
            mapDict:(first each COL_MAP)!(last each COL_MAP);
            mappedCols:{$[x in key y; y x; x]}[;mapDict] each srcCols;
        ];

        srcTypeStr:.batch.buildSrcTypeStr[mappedCols];
        .log.info[("Source columns: [%s] -> types: [%s]";", " sv string srcCols;srcTypeStr)];

        $[STREAM;
            // Sequential read for FIFO pipes
            .batch.readStream[FILE;DELIMITER;srcTypeStr;hdrLine];
          fileSize>=CHUNK_THRESHOLD;
            // Chunked read for large files
            .batch.readChunked[FILE;DELIMITER;srcTypeStr;hdrLine;CHUNK_THRESHOLD];
          // else: single pass
            [
                data:.batch.readFull[FILE;DELIMITER;srcTypeStr];
                .batch.processChunk[data];
            ]
        ];
    ];
  FILE_TYPE=`parquet;
    [
        data:.batch.readParquet[FILE];
        .batch.processChunk[data];
    ];
  // else
    [
        .log.error["Unsupported file type: ",string FILE_TYPE];
        exit 1;
    ]
 ];

// Post-load: set .d file, apply grouped attribute on sym, fill missing partitions
partPath:.batch.partPath[];
if[not ()~key partPath;
    (` sv partPath,`.d) set schemaCols;
    symFile:` sv partPath,`sym;
    symFile set `g#get symFile;
    .log.info["Applied g# attribute to sym column"];
 ];

// Fill missing tables across all date partitions (prevents query errors)
.Q.chk[HDB_DIR];
.log.info["Ran .Q.chk to fill missing partitions"];

.log.info[("Batch load complete | table=[%s] date=[%s] rows=[%d]";string TABLE;string DATE;.batch.totalRows)];
exit 0;
