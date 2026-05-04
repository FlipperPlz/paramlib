class CfgSchemas {
    class DayZ {
        stringCompletions[] += {
            {"**.uvSource", {"none", "tex", "texwateranim", "pos", "norm", "tex1", "worldpos",  "worldnorm", "texshoreanim"}},
        };
        arrayInlays[] += {
            {"**.pos[3]",                {"x", "y", "z"}},
            {"**.uvTransform.aside[3]",  {"x", "y", "z"}},
            {"**.uvTransform.up[3]",     {"x", "y", "z"}},
            {"**.uvTransform.dir[3]",    {"x", "y", "z"}},
            {"**.itemsCargoSize[2]",     {"width", "height"}},
            {"**.offset[3]",             {"x", "y", "z"}},
            {"**.itemSize[2]",           {"width", "height"}}
        };
        parsers[] += {
            {"**.forcedDiffuse*", "internal:color"},
            {"**.*Color",         "internal:color"},
            {"**.color*",         "internal:color"},
            {"**.ambient",        "internal:color"},
            {"**.diffuse",        "internal:color"},
            {"**.specular",       "internal:color"},
            {"**.emmisive",       "internal:color"},
            {"**.texture*",       "internal:texture_source"},
        };
    };
};
