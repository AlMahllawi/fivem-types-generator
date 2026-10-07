/*
Copyright (C) 2026 Mohammad AlMahllawi
SPDX-License-Identifier: GPL-3.0-or-later
*/

import * as vscode from 'vscode';
import * as path from 'path';
import { execFile, exec } from 'child_process';

const diagnosticCollection = vscode.languages.createDiagnosticCollection('fivem-lua-definitions');

export function activate(context: vscode.ExtensionContext) {
    context.subscriptions.push(diagnosticCollection);

    const luaExtension = vscode.extensions.getExtension('sumneko.lua');
    if (!luaExtension) {
        vscode.window.showErrorMessage('Lua extension is required!');
        return;
    }

    const extensionPath = luaExtension.extensionPath;
    const isWindows = process.platform === 'win32';
    const binaryName = isWindows ? 'lua-language-server.exe' : 'lua-language-server';
    const lualsBinaryPath = path.join(extensionPath, 'server', 'bin', binaryName);
    const scriptPath = path.join(context.extensionPath, 'generator.lua');

    const statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    statusBarItem.command = 'fivem.showConfigurationMenu';
    context.subscriptions.push(statusBarItem);

    const getGuessedName = () => {
        const folders = vscode.workspace.workspaceFolders;
        return folders && folders.length > 0 ? path.basename(folders[0].uri.fsPath) : 'unknown';
    };

    const updateStatusBar = () => {
        const name = context.workspaceState.get<string>('resourceName') || getGuessedName();
        const outDir = context.workspaceState.get<string>('outputDir') || 'definitions';
        statusBarItem.text = `$(package) FiveM: ${name} $(arrow-right) ${outDir}`;
        statusBarItem.tooltip = 'Click to configure FiveM Lua Definitions Generator';
        statusBarItem.show();
    };

    updateStatusBar();

    const changeNameCommand = vscode.commands.registerCommand('fivem.changeResourceName', async () => {
        const guessedName = getGuessedName();
        let currentName = context.workspaceState.get<string>('resourceName') || guessedName;
        
        const inputName = await vscode.window.showInputBox({
            prompt: 'Enter resource name for exported definitions',
            value: currentName,
            placeHolder: guessedName
        });
        
        if (inputName !== undefined) {
            await context.workspaceState.update('resourceName', inputName.trim() === '' ? undefined : inputName.trim());
            updateStatusBar();
        }
    });

    const changeOutDirCommand = vscode.commands.registerCommand('fivem.changeOutputDir', async () => {
        let currentOutDir = context.workspaceState.get<string>('outputDir') || 'definitions';
        
        const inputDir = await vscode.window.showInputBox({
            prompt: 'Enter output directory for exported definitions (relative to resource root)',
            value: currentOutDir,
            placeHolder: 'definitions'
        });
        
        if (inputDir !== undefined) {
            await context.workspaceState.update('outputDir', inputDir.trim() === '' ? undefined : inputDir.trim());
            updateStatusBar();
        }
    });

    const showConfigurationMenuCommand = vscode.commands.registerCommand('fivem.showConfigurationMenu', async () => {
        const selection = await vscode.window.showQuickPick([
            { label: '$(edit) Change Resource Name', description: context.workspaceState.get<string>('resourceName') || getGuessedName(), command: 'fivem.changeResourceName' },
            { label: '$(folder) Change Output Directory', description: context.workspaceState.get<string>('outputDir') || 'definitions', command: 'fivem.changeOutputDir' }
        ], { placeHolder: 'Configure FiveM Lua Definitions Generator' });

        if (selection) {
            vscode.commands.executeCommand(selection.command);
        }
    });

    context.subscriptions.push(changeNameCommand, changeOutDirCommand, showConfigurationMenuCommand);

    const generateCommand = vscode.commands.registerCommand('fivem.generateDefinitions', async (autoRun?: boolean) => {
        const workspaceFolders = vscode.workspace.workspaceFolders;
        if (!workspaceFolders) {
            if (!autoRun) vscode.window.showErrorMessage('No workspace folder open.');
            return;
        }

        const resourcePath = workspaceFolders[0].uri.fsPath;
        const resourceName = context.workspaceState.get<string>('resourceName') || getGuessedName();
        
        // Notify first time auto-run happens and name was guessed
        if (autoRun && !context.workspaceState.get<boolean>('hasNotifiedAutoName')) {
            vscode.window.showInformationMessage(`FiveM Lua Definitions: Using '${resourceName}' as the resource name. Click the status bar to change it.`);
            await context.workspaceState.update('hasNotifiedAutoName', true);
        }

        const args = [scriptPath, '--json'];
        if (resourceName && resourceName !== '') {
            args.push('--name', resourceName);
        }
        args.push(resourcePath);
        
        let outDir = context.workspaceState.get<string>('outputDir');
        if (outDir && outDir.trim() !== '') {
            if (!path.isAbsolute(outDir)) {
                outDir = path.join(resourcePath, outDir);
            }
            args.push(outDir);
        }

        execFile(lualsBinaryPath, args, (error, stdout, stderr) => {
            diagnosticCollection.clear();
            
            if (error && !stdout) {
                vscode.window.showErrorMessage(`Failed to generate definitions: ${error.message}`);
                return;
            }

            try {
                // Find where the JSON begins, in case lua-language-server printed some prefix logs to stdout
                const jsonStart = stdout.indexOf('{');
                const jsonStr = jsonStart >= 0 ? stdout.substring(jsonStart) : stdout;
                const result = JSON.parse(jsonStr);
                
                if (!result.success) {
                    const errMsgs = result.errors ? result.errors.map((e: any) => e.message).join(', ') : 'Unknown error';
                    vscode.window.showErrorMessage(`Generator failed: ${errMsgs}`);
                    return;
                }

                if (result.warnings && result.warnings.length > 0) {
                    const diagnosticsMap = new Map<string, vscode.Diagnostic[]>();
                    for (const w of result.warnings) {
                        const uri = vscode.Uri.file(w.file);
                        const line = Math.max(0, w.line - 1);
                        const range = new vscode.Range(line, 0, line, 100);
                        const diagnostic = new vscode.Diagnostic(range, w.message, vscode.DiagnosticSeverity.Warning);
                        diagnostic.source = 'FiveM Lua Definitions Generator';
                        
                        const uriString = uri.toString();
                        if (!diagnosticsMap.has(uriString)) diagnosticsMap.set(uriString, []);
                        diagnosticsMap.get(uriString)!.push(diagnostic);
                    }

                    for (const [uriString, diagnostics] of diagnosticsMap.entries()) {
                        diagnosticCollection.set(vscode.Uri.parse(uriString), diagnostics);
                    }
                    
                    vscode.window.showWarningMessage(`FiveM lua definitions generated with ${result.warnings.length} warning(s). Check the Problems tab.`);
                } else {
                    if (!autoRun) {
                        vscode.window.showInformationMessage('FiveM lua definitions generated successfully!');
                    }
                }
            } catch (e) {
                vscode.window.showErrorMessage(`Failed to parse generator output: ${e instanceof Error ? e.message : 'Unknown JSON parse error'}`);
                if (stderr) console.error("Generator Stderr:", stderr);
            }
        });
    });
    
    context.subscriptions.push(generateCommand);

    const syncDefinitionsCommand = vscode.commands.registerCommand('fivem.syncDefinitions', () => {
        const workspaceFolders = vscode.workspace.workspaceFolders;
        if (!workspaceFolders) {
            vscode.window.showErrorMessage('No workspace folder open.');
            return;
        }

        const cwd = workspaceFolders[0].uri.fsPath;
        const scriptName = isWindows ? 'sync.ps1' : 'sync.sh';
        const scriptPath = path.join(context.extensionPath, scriptName);

        vscode.window.withProgress({
            location: vscode.ProgressLocation.Notification,
            title: 'Syncing Lua Definitions...',
            cancellable: false
        }, async (progress) => {
            return new Promise<void>((resolve) => {
                const command = isWindows
                    ? `powershell -ExecutionPolicy Bypass -File "${scriptPath}"`
                    : `bash "${scriptPath}"`;

                exec(command, { cwd }, (error, stdout, stderr) => {
                    if (error) {
                        vscode.window.showErrorMessage(`Sync failed. Check output for details.\n${error.message}`);
                        console.error('Sync Error:', stderr || stdout);
                    } else if (stdout.includes('[!] WARNING') || stderr.includes('[!] WARNING')) {
                        vscode.window.showWarningMessage('Sync completed with warnings. Check console for details.');
                        console.warn('Sync Warnings:', stdout);
                    } else {
                        vscode.window.showInformationMessage('Lua definitions synced successfully!');
                    }
                    resolve();
                });
            });
        });
    });
    context.subscriptions.push(syncDefinitionsCommand);

    let debounceTimer: NodeJS.Timeout | undefined;
    const saveListener = vscode.workspace.onDidSaveTextDocument((document) => {
        const config = vscode.workspace.getConfiguration('fivemLuaDefinitions');
        const generateOnSave = config.get<boolean>('generateOnSave', true);
        if (!generateOnSave) {
            return;
        }

        if (document.fileName.endsWith('fxmanifest.lua') || document.fileName.endsWith('__resource.lua')) {
            if (debounceTimer) {
                clearTimeout(debounceTimer);
            }
            debounceTimer = setTimeout(() => {
                vscode.commands.executeCommand('fivem.generateDefinitions', true);
            }, 1000);
        }
    });
    context.subscriptions.push(saveListener);

    context.subscriptions.push(
        vscode.languages.registerCodeActionsProvider('lua', new IgnoreWarningCodeActionProvider(), {
            providedCodeActionKinds: IgnoreWarningCodeActionProvider.providedCodeActionKinds
        })
    );

    context.subscriptions.push(vscode.commands.registerCommand('fivem.handleQuickFixApplied', (uri: vscode.Uri, range: vscode.Range) => {
        const diagnostics = diagnosticCollection.get(uri);
        if (diagnostics) {
            const updated = diagnostics.filter(d => 
                !(d.source === 'FiveM Lua Definitions Generator' && d.range.start.line === range.start.line)
            );
            diagnosticCollection.set(uri, updated);
        }
    }));
}

export function deactivate() {}

export class IgnoreWarningCodeActionProvider implements vscode.CodeActionProvider {
    public static readonly providedCodeActionKinds = [
        vscode.CodeActionKind.QuickFix
    ];

    public provideCodeActions(document: vscode.TextDocument, range: vscode.Range | vscode.Selection, context: vscode.CodeActionContext, token: vscode.CancellationToken): vscode.CodeAction[] {
        const actions: vscode.CodeAction[] = [];
        
        for (const diagnostic of context.diagnostics) {
            if (diagnostic.source === 'FiveM Lua Definitions Generator' && diagnostic.message === 'Could not resolve dynamic export name') {
                const line = diagnostic.range.start.line;
                const prevLine = line > 0 ? document.lineAt(line - 1).text : '';
                
                // Do not offer quick fix if the ignore comment is already present above
                if (prevLine.includes('---@definitions-generator-ignore')) {
                    continue;
                }

                const fix = new vscode.CodeAction(`Add ---@definitions-generator-ignore`, vscode.CodeActionKind.QuickFix);
                fix.edit = new vscode.WorkspaceEdit();
                const lineText = document.lineAt(line).text;
                const indentation = lineText.substring(0, lineText.search(/\S|$/));
                fix.edit.insert(document.uri, new vscode.Position(line, 0), `${indentation}---@definitions-generator-ignore\n`);
                fix.diagnostics = [diagnostic];
                fix.isPreferred = true;
                fix.command = {
                    command: 'fivem.handleQuickFixApplied',
                    title: 'Handle Quick Fix Applied',
                    arguments: [document.uri, diagnostic.range]
                };
                actions.push(fix);
            }
        }
        
        return actions;
    }
}
