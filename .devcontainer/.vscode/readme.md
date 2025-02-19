# Personalized settings

We gitignore .devcontainer/.vscode/settings.json to allow you to test and add your own extensions or configs.

examples of settings.json

```json
{
    
}
```

Pylance settings

```json
{

    /******************************************/
    /**** Workspace-wide settings ****/
    /******************************************/

    // Exclude all files from workspace, enabling IntelliSense support for open files only
    // "python.analysis.exclude": ["**"],

    // Disable indexing for workspace & third-party libraries
    // "python.analysis.indexing": false,

    // Enable problem reporting only for open files, instead of all files in the workspace
    // "python.analysis.diagnosticMode": "openFilesOnly",

    /**************************************/
    /**** Features with custom support ****/
    /**************************************/

    // Disable custom parsing of reStructedText docstrings
    // "python.analysis.supportRestructuredText": false,

    // Disable custom pytest IntelliSense features
    // "python.analysis.enablePytestSupport": false,


    /**********************/
    /**** Inlay hints ****/
    /*********************/

    // Disable inlay hints
    // "python.analysis.inlayHints.callArgumentNames": "off",
    // "python.analysis.inlayHints.functionReturnTypes": false,
    // "python.analysis.inlayHints.pytestParameters": false,
    // "python.analysis.inlayHints.variableTypes": false,

    /************************/
    /**** Type features ****/
    /***********************/

    // Disable type checking diagnostics
    // "python.analysis.typeCheckingMode": "off",

    // Disable extracting type information from library implementations
    // "python.analysis.useLibraryCodeForTypes": false,

    /*************************/
    /**** Editor features ****/
    /*************************/

    // Disable semantic highlighting
    // "editor.semanticHighlighting.enabled": false,

    // Disable occurrences highlighting when selecting a symbol
    // "editor.occurrencesHighlight": "off",

    /************************************/
    /*** Less perf intensive features ***/
    /************************************/

    // Whether to automatically complete parenthesis when accepting a function suggestion
    // "python.analysis.completeFunctionParens": false,

    // Whether to automatically convert a string to an f-string when adding "{}"
    // "python.analysis.autoFormatStrings": false,

    // Whether to enable auto import suggestions
    // "python.analysis.autoImportCompletions": false,

    // Whether to enable code navigation for string literals that look like module names
    //  "python.analysis.gotoDefinitionInStringLiteral": false,
}
```
