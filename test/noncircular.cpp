class Parent {
    class Oldest {
        class InnerLeast {
            value = 0;
        };
    };
    class Youngest : Oldest {
        class InnerLeast : InnerLeast {};
    };
};