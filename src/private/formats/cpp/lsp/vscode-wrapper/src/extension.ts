import * as vscode from "vscode";
import * as path from "path";
import * as fs from "fs";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
  Executable,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

function resolveServerPath(): string {
  const cfg = vscode.workspace.getConfiguration("paramlibLsp");
  const explicit = cfg.get<string>("serverPath");
  if (explicit && explicit.length > 0) {
    if (fs.existsSync(explicit)) return explicit;
    vscode.window.showWarningMessage(
      `paramlib-lsp: configured serverPath "${explicit}" not found — falling back to auto-detect.`
    );
  }

  const workspaceFolders = vscode.workspace.workspaceFolders;
  if (workspaceFolders && workspaceFolders.length > 0) {
    const root = workspaceFolders[0].uri.fsPath;
    const candidate = path.join(root, "zig-out", "bin", "paramlib-lsp");
    if (fs.existsSync(candidate)) return candidate;
  }

  return "paramlib-lsp";
}

export function activate(context: vscode.ExtensionContext): void {
  const serverBin = resolveServerPath();

  const serverExe: Executable = {
    command: serverBin,
    transport: TransportKind.stdio,
  };

  const serverOptions: ServerOptions = {
    run:   serverExe,
    debug: serverExe,
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "paramlib" }],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher("**/*.param"),
    },
    traceOutputChannel: vscode.window.createOutputChannel("Paramlib LSP Trace"),
  };

  client = new LanguageClient(
    "paramlibLsp",
    "Paramlib LSP",
    serverOptions,
    clientOptions
  );

  client.start();
  context.subscriptions.push(client);
}

export function deactivate(): Promise<void> | undefined {
  return client?.stop();
}
