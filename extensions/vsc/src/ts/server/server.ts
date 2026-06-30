import { createConnection, ProposedFeatures } from 'vscode-languageserver/node';
import { startServer } from './serverFactory';

startServer(() => createConnection(ProposedFeatures.all));
