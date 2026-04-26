class CfgSchemas {
    class DayZ {
        stringCompletions[] += {
            {"**.Stage*.uvSource", {"tex", "pos", "norm"}},
        };
        arrayInlays[] += {
            {"**.color[4]", {"red", "green", "blue", "alpha"}},
            {"**.ambient[4]", {"red", "green", "blue", "alpha"}},
            {"**.diffuse[4]", {"red", "green", "blue", "alpha"}},
            {"**.specular[4]", {"red", "green", "blue", "alpha"}},
            {"**.pos[3]", {"x", "y", "z"}},
            {"**.offset[3]", {"x", "y", "z"}}
        };
    };
};