// Load utility scripts
system"l utils/main.q";

.log.info["Initialising FH"];

//Open connection to TP
TP_H:hopen`$"::",first CLI_ARGS[`tpPort];

//Ingest data with custom logic
system"l parseCustomData.q";
energyData:.load.data[50;`energy;"KwhConsumptionBlower78_1.csv"];
weatherData:.load.data[50;`weather;"weather_data.csv"];

//Live data stimulation of data
.z.ts:{[] 
        neg[TP_H](".u.upd";`energy;energyData);
        neg[TP_H](".u.upd";`weather;weatherData)
    };

//Publish data every second to TP
system"t 1000"

//To stop publishing  
/system"t 0"
