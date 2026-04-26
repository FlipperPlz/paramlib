// @ts-check
"use strict";
/** @typedef {import('webpack').Configuration} WebpackConfig **/


const path = require("path");
const CopyPlugin = require("copy-webpack-plugin");
const webpack = require("webpack");

const { name, publisher, version } = require("./package.json");

const PRODUCTION = process.env.NODE_ENV === "production";
const TEST = process.env.NODE_ENV === "test";

/** @type WebpackConfig["mode"] */
const mode = PRODUCTION ? "production" : "none";
/** @type WebpackConfig["devtool"] */
const devtool = PRODUCTION ? false : "source-map";

let extensionURL = `https://${publisher}.vscode-unpkg.net/${publisher}/${name}/${version}/extension/server/dist/`;
let schemasURL   = `https://${publisher}.vscode-unpkg.net/${publisher}/${name}/${version}/extension/schemas/`;

const swcLoader = {
    test: /\.ts$/,
    exclude: /node_modules/,
    use: [{ loader: "swc-loader" }],
};

const browserOutput = {
    filename: "[name].js",
    path: path.join(__dirname, "client", "dist"),
    libraryTarget: "commonjs",
};

const browserResolve = {
    extensions: [".ts", ".js"],
    fallback: { path: require.resolve("path-browserify") },
};

/** @type WebpackConfig */
const clientBrowserConfig = {
    context: path.join(__dirname, "client"),
    mode,
    devtool,
    target: "webworker",
    entry: {
        clientBrowser: "./src/clientBrowser.ts",
    },
    output: browserOutput,
    resolve: browserResolve,
    plugins: [
        new webpack.DefinePlugin({
            __DEV_MODE__:   JSON.stringify(!PRODUCTION),
            __SCHEMAS_URL__: JSON.stringify(schemasURL),
        }),
    ],
    module: { rules: [swcLoader] },
    externals: { vscode: "commonjs vscode" },
};

const serverOutput = {
    filename: "[name].js",
    path: path.join(__dirname, "server", "dist"),
    libraryTarget: "var",
    library: "serverExportVar",
};

const serverBrowserConfig = {
    context: path.join(__dirname, "server"),
    mode,
    devtool,
    target: "webworker",
    entry: { serverBrowser: "./src/serverBrowser.ts" },
    output: serverOutput,
    resolve: { extensions: [".ts", ".js"] },
    plugins: [
        new webpack.DefinePlugin({
            __EXTENSION_URL__: JSON.stringify(extensionURL),
        }),
        new CopyPlugin({
            patterns: [{
                from: path.resolve(__dirname, "../zig-out/wasm/paramlib-lsp.wasm"),
                to: path.join(__dirname, "server", "dist", "paramlib-lsp.wasm"),
            }],
        }),
    ],
    module: {
        rules: [swcLoader],
    }
};

/** @type WebpackConfig */
const serverNodeConfig = {
    context: path.join(__dirname, "server"),
    mode,
    devtool,
    target: "node",
    entry: { serverNode: "./src/serverNode.ts" },
    output: serverOutput,
    resolve: { extensions: [".ts", ".js"] },
    plugins: [
        new CopyPlugin({
            patterns: [{
                from: path.resolve(__dirname, "../zig-out/wasm/paramlib-lsp.wasm"),
                to: path.join(__dirname, "server", "dist"),
            }],
        }),
    ],
    module: { rules: [swcLoader] },
};


/** @type WebpackConfig */
const clientNodeConfig = {
    context: path.join(__dirname, "client"),
    mode,
    devtool,
    target: "node",
    entry: { clientNode: "./src/clientNode.ts" },
    output: browserOutput,
    resolve: browserResolve,
    plugins: [
        new webpack.DefinePlugin({
            __DEV_MODE__: JSON.stringify(!PRODUCTION),
        }),
    ],
    module: { rules: [swcLoader] },
    externals: { vscode: "commonjs vscode" },
};

// const dapNodeConfig = {
//     context: path.join(__dirname, "debug"),
//     mode,
//     devtool,
//     target: "node",
//     entry: { debug: "./debug.ts" },
//     output: {
//         filename: "[name].js",
//         path: path.join(__dirname, "debug", "dist"),
//         libraryTarget: "var",
//         library: "serverExportVar",
//     },
//     module: { rules: [swcLoader] },
// };
module.exports = [
    clientBrowserConfig,
    clientNodeConfig,
    serverBrowserConfig,
    serverNodeConfig,
    // dapNodeConfig,
];