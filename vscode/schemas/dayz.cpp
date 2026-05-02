class CfgSchemas {
    class DayZ {
        stringCompletions[] += {
            {"**.Stage*.uvSource", {"tex", "pos", "norm"}},
        };
        arrayInlays[] += {
            {"**.pos[3]",            {"x", "y", "z"}},
            {"**.itemsCargoSize[2]", {"width", "height"}},
            {"**.offset[3]",         {"x", "y", "z"}},
            {"**.itemSize[2]",       {"width", "height"}}
        };
        parsers[] += {
            {"**.forcedDiffuse*", "internal:color"},
            {"**.*Color",         "internal:color"},
            {"**.color*",         "internal:color"},
            {"**.ambient",        "internal:color"},
            {"**.diffuse",        "internal:color"},
            {"**.specular",       "internal:color"},
            {"**.emmisive",       "internal:color"}
        };
    };
};
