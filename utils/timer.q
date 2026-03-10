// Simple timer hooks to define logic for timers in multiple places
.timer.funcs:()!();

// Execute any function in the .timer.funcs namespace
//  - expects functions to have null input {[]}
.z.ts:{
    value[.timer.funcs]@\:(::);
 };

// set \t in respective scripts

// Example function definitions
/
.timer.funcs[`func1]:{[] show .z.p};
.timer.funcs[`func2]:{[] show .z.t;};