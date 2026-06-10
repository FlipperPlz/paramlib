class CfgSchemas {
    class DayZ;

    class MyProject : DayZ {
        parsers[] -= {
            {"**.forcedDiffuse*", "internal:color"         }
        };
    };
};
