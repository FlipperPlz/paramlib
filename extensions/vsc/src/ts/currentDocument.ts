import * as vscode from 'vscode';

export class CurrentDocumentTracker implements vscode.Disposable {
  private readonly emitter = new vscode.EventEmitter<vscode.TextDocument | undefined>();
  private readonly subscription: vscode.Disposable;
  private _current: vscode.TextDocument | undefined;

  readonly onDidChangeCurrentDocument = this.emitter.event;

  constructor() {
    this._current = vscode.window.activeTextEditor?.document;

    this.subscription = vscode.window.onDidChangeActiveTextEditor((editor) => {
      this._current = editor?.document;
      this.emitter.fire(this._current);
    });

    if (this._current) {
      this.emitter.fire(this._current);
    }
  }

  get currentDocument(): vscode.TextDocument | undefined {
    return this._current;
  }

  dispose(): void {
    this.subscription.dispose();
    this.emitter.dispose();
  }
}
