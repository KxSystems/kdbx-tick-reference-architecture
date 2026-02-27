//This script contains custom logic to parse in example data to the feedhandler

//Get data directory
sampleDataDir:getenv `SAMPLE_DATA;

//Ingest Energy data from csv file
.parse.energy:{[csvFile]
        //Load CSV
        energyRaw:("IDTF";enlist ",") 0: `$(sampleDataDir,"/",csvFile);
        //Rename columns
        energyRaw:`idx`date`timeWindow`consumption xcol energyRaw;
        //Update to include time and sym columns
        energyTab:update time:(count timeWindow)#.z.n, sym:`$string idx from energyRaw;
        //Remove idx column
        energyTab:delete idx from energyTab;
        //Reorder cols to match TP schema
        `time`sym`date`timeWindow`consumption xcols energyTab
    };

//Ingest Weather data from csv file
.parse.weather:{[csvFile]
        //Load CSV
        weatherRaw:("SZFFFF";enlist ",") 0: `$(sampleDataDir,"/",csvFile);
        //Rename columns
        weatherRaw:`location`dateTime`temp`humidity`precipitation`windSpeed xcol weatherRaw;
        //Update to include time and sym columns
        weatherTab:update time:(count dateTime)#.z.n, sym:location from weatherRaw;
        //Delete location
        weatherTab:delete location from weatherTab;
        //Reorder cols to match TP schema
        `time`sym`dateTime`temp`humidity`precipitation`windSpeed xcols weatherTab
    };

//Function to load in the data
.load.data:{[num;tabName;csvFile]
                $[`energy=tabName; 
                        //Select custom number of rows from csv file
                        tab:num#(select from .parse.energy[csvFile]);
                    `weather=tabName;
                        tab:num#(select from .parse.weather[csvFile]);
                ];    
                //Return data in column list
                tab[cols tab]
            };
