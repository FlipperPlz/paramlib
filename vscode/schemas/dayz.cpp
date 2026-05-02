class CfgSchemas {
    class DayZ {
        stringCompletions[] += {
            {"**.Stage*.uvSource", {"tex", "pos", "norm"}},
        };
        arrayInlays[] += {
            {"**.pos[3]", {"x", "y", "z"}},
            {"**.offset[3]", {"x", "y", "z"}}
        };
        parsers[] += {
            {"**.color", "internal:color"},
            {"**.ambient", "internal:color"},
            {"**.diffuse", "internal:color"},
            {"**.specular", "internal:color"},
            {"**.emmisive", "internal:color"}
        };
    };
};
