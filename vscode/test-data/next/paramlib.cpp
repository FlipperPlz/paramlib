class CfgSchemas {
    class MyProject;

    class NextProject : MyProject {
        parsers[] += {
                {"**.forcedDiffuse*", "internal:color"         }
        };
    };
};
