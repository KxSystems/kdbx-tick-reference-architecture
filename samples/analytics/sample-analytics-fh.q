//Sample script for parsing in sample data to the FH. 

//Get data directory
customDataDir:getenv `CUSTOM_DATA;

//Ingest Energy data from csv file
.fh.parse.energy:{[csvFile]
        //Load CSV
        energyRaw:("IDTF";enlist ",") 0: `$(customDataDir,"/",csvFile);
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
.fh.parse.weather:{[csvFile]
        //Load CSV
        weatherRaw:("SZFFFF";enlist ",") 0: `$(customDataDir,"/",csvFile);
        //Rename columns
        weatherRaw:`location`dateTime`temp`humidity`precipitation`windSpeed xcol weatherRaw;
        //Update to include time and sym columns
        weatherTab:update time:(count dateTime)#.z.n, sym:location from weatherRaw;
        //Delete location
        weatherTab:delete location from weatherTab;
        //Reorder cols to match TP schema
        `time`sym`dateTime`temp`humidity`precipitation`windSpeed xcols weatherTab
    };

//Upsert data to TP
.fh.upsert.data:{[]
        neg[TP_H](".u.upd";`energy;value flip (select from .fh.parse.energy["KwhConsumptionBlower78_1.csv"])); 
        neg[TP_H](".u.upd";`weather;value flip (select from .fh.parse.weather["weather_data.csv"]));
    };


    
