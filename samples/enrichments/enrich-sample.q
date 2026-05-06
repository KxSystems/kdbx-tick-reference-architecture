/Enrichment file will define enrichment functions:
/ sampleEnrich: {[t;x] //do some enrichment to x; .rte.publish[enrichedTableName;enrichedData]};
/Register the enrichment function and subscriptions for target table:
/ .rte.addEnrichment[`sampleEnrich;`targetTable];
/ .rte.addSubscription[`targetTable;`];

/Sample RTE analytic - calculates heat index and publishes to table 'weatherHeatIndex'

/fahrenheit to celsius conversion
/f - float, temperature in fahrenheit
fToC: {[f]
    :(5%9) * (f-32);
    };
/function to calculate heat index
/temp - float, temperature in celsius
/humidity - float, relative humidity percentage
calcHeatIndex:{[temp;humidity]
    /https://en.wikipedia.org/wiki/Heat_index
    /constants for heat index calculation
    c: 0 -8.78469475556 1.61139411 2.33854883889 -0.14611605 -0.012308094 -0.0164248277778 2.211732e-3 7.2546e-4 -3.582e-6;
    /calculate heat index
    hi_f: (c[1]) + (c[2]*temp) + (c[3]*humidity) + (c[4]*temp*humidity) + (c[5]*temp*temp) + (c[6]*humidity*humidity) + (c[7]*temp*temp*humidity) + (c[8]*temp*humidity*humidity) + (c[9]*temp*temp*humidity*humidity);
    /convert to celsius (formula returns fahrenheit)
    :fToC hi_f
    };
/analytic to run on incoming data
/data - table, weather data entry
addHeatIndex:{[data].rte.pub[`weatherHeatIndex;select time, sym, dateTime, heatIndex:calcHeatIndex'[temp;humidity] from data]};

/Add the analytic & subscription to RTE
.log.info["heat-index - Registering heat index analytic + subscription for weather table"];
.rte.addEnrichment[`addHeatIndex;`weather];
.rte.addSubscription[`weather;`];
