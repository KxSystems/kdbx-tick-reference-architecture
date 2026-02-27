//Open connection to TP
h:hopen 6010;

//Ingest data with custom logic
system"l parseCustomData.q";

// 
energyData:.load.data[50;`energy;"KwhConsumptionBlower78_1.csv"];
weatherData:.load.data[50;`weather;"weather_data.csv"];

//Live data stimulation of data
.z.ts:{[] 
        neg[h](".u.upd";`energy;energyData);
        neg[h](".u.upd";`weather;weatherData)
    };

//Publish data every second to TP
system"t 1000"

//To stop publishing  
/system"t 0"
