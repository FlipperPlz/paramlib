import {
  BrowserMessageReader,
  BrowserMessageWriter,
  createConnection,
  ProposedFeatures,
} from 'vscode-languageserver/browser';
import { startServer } from './serverFactory';

startServer(() => {
  const reader = new BrowserMessageReader(self as unknown as Worker);
  const writer = new BrowserMessageWriter(self as unknown as Worker);
  return createConnection(ProposedFeatures.all, reader, writer);
});
