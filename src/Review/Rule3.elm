module Review.Rule3 exposing
    ( ModuleRuleSchema
    , ProjectRuleSchema
    , fromModuleRuleSchema
    , fromProjectRuleSchema
    , newModuleRuleSchema
    , newProjectRuleSchema
    , withCommentsVisitor
    , withContextFromImportedModules
    , withDeclarationEnterVisitor
    , withDeclarationExitVisitor
    , withDeclarationListVisitor
    , withDeclarationVisitor
    , withDependenciesProjectVisitor
    , withElmJsonProjectVisitor
    , withExpressionEnterVisitor
    , withExpressionExitVisitor
    , withExpressionVisitor
    , withFinalModuleEvaluation
    , withFinalProjectEvaluation
    , withImportVisitor
    , withModuleContext
    , withModuleDefinitionVisitor
    , withModuleVisitor
    , withReadmeProjectVisitor
    , withSimpleCommentsVisitor
    , withSimpleDeclarationVisitor
    , withSimpleExpressionVisitor
    , withSimpleImportVisitor
    , withSimpleModuleDefinitionVisitor
    )

import Dict exposing (Dict)
import Elm.Project
import Elm.Syntax.Declaration exposing (Declaration)
import Elm.Syntax.Expression exposing (Expression)
import Elm.Syntax.Import exposing (Import)
import Elm.Syntax.Module exposing (Module)
import Elm.Syntax.ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node exposing (Node)
import Elm.Syntax.Range as Range
import Review.Context as Context exposing (Context)
import Review.Exceptions as Exceptions exposing (Exceptions)
import Review.Metadata as Metadata
import Review.Project.Dependency
import Review.Rule exposing (CacheEntry, CacheEntryFor, Direction(..), ElmJsonKey(..), Error(..), Forbidden, ModuleKey(..), ModuleRuleResultCache, ModuleVisitorFunctions, ProjectRuleCache, ReadmeKey(..), Required, Rule(..), TraversalType(..), Visitor, removeErrorPhantomType)
import Review.Visitor exposing (Folder)


type ProjectRuleSchema schemaState projectContext moduleContext
    = ProjectRuleSchema
        { name : String
        , initialProjectContext : projectContext
        , elmJsonVisitors : List (Maybe { elmJsonKey : ElmJsonKey, project : Elm.Project.Project } -> projectContext -> ( List (Error {}), projectContext ))
        , readmeVisitors : List (Maybe { readmeKey : ReadmeKey, content : String } -> projectContext -> ( List (Error {}), projectContext ))
        , dependenciesVisitors : List (Dict String Review.Project.Dependency.Dependency -> projectContext -> ( List (Error {}), projectContext ))
        , moduleVisitors : List (ModuleRuleSchema {} moduleContext -> ModuleRuleSchema { hasAtLeastOneVisitor : () } moduleContext)
        , moduleContextCreator : Maybe (Context projectContext moduleContext)
        , folder : Maybe (Folder projectContext moduleContext)

        -- TODO Jeroen Only allow to set it if there is a folder, but not several times
        , traversalType : TraversalType
        , finalEvaluationFns : List (projectContext -> List (Error {}))
        }


newProjectRuleSchema : String -> projectContext -> ProjectRuleSchema { canAddModuleVisitor : (), withModuleContext : Forbidden } projectContext moduleContext
newProjectRuleSchema name initialProjectContext =
    ProjectRuleSchema
        { name = name
        , initialProjectContext = initialProjectContext
        , elmJsonVisitors = []
        , readmeVisitors = []
        , dependenciesVisitors = []
        , moduleVisitors = []
        , moduleContextCreator = Nothing
        , folder = Nothing
        , traversalType = AllModulesInParallel
        , finalEvaluationFns = []
        }


type alias ModuleContextFunctions projectContext moduleContext =
    { fromProjectToModule : ModuleKey -> Node ModuleName -> projectContext -> moduleContext
    , fromModuleToProject : ModuleKey -> Node ModuleName -> moduleContext -> projectContext
    , foldProjectContexts : projectContext -> projectContext -> projectContext
    }


type ModuleRuleSchema schemaState moduleContext
    = ModuleRuleSchema
        { name : String
        , initialModuleContext : Maybe moduleContext
        , moduleContextCreator : Context () moduleContext
        , moduleDefinitionVisitors : List (Visitor Module moduleContext)
        , commentsVisitors : List (List (Node String) -> moduleContext -> ( List (Error {}), moduleContext ))
        , importVisitors : List (Visitor Import moduleContext)
        , declarationListVisitors : List (List (Node Declaration) -> moduleContext -> ( List (Error {}), moduleContext ))
        , declarationVisitorsOnEnter : List (Visitor Declaration moduleContext)
        , declarationVisitorsOnExit : List (Visitor Declaration moduleContext)
        , expressionVisitorsOnEnter : List (Visitor Expression moduleContext)
        , expressionVisitorsOnExit : List (Visitor Expression moduleContext)
        , finalEvaluationFns : List (moduleContext -> List (Error {}))
        }


withModuleVisitor :
    (ModuleRuleSchema {} moduleContext -> ModuleRuleSchema { hasAtLeastOneVisitor : () } moduleContext)
    -> ProjectRuleSchema { projectSchemaState | canAddModuleVisitor : () } projectContext moduleContext
    -- TODO BREAKING Change: add hasAtLeastOneVisitor : ()
    -> ProjectRuleSchema { projectSchemaState | canAddModuleVisitor : (), withModuleContext : Required } projectContext moduleContext
withModuleVisitor visitor (ProjectRuleSchema schema) =
    ProjectRuleSchema { schema | moduleVisitors = visitor :: schema.moduleVisitors }


newModuleRuleSchema : String -> moduleContext -> ModuleRuleSchema { moduleContext : Required } moduleContext
newModuleRuleSchema name initialModuleContext =
    ModuleRuleSchema
        { name = name
        , initialModuleContext = Just initialModuleContext
        , moduleContextCreator = Context.init (always initialModuleContext)
        , moduleDefinitionVisitors = []
        , commentsVisitors = []
        , importVisitors = []
        , declarationListVisitors = []
        , declarationVisitorsOnEnter = []
        , declarationVisitorsOnExit = []
        , expressionVisitorsOnEnter = []
        , expressionVisitorsOnExit = []
        , finalEvaluationFns = []
        }


withModuleContext :
    { fromProjectToModule : ModuleKey -> Node ModuleName -> projectContext -> moduleContext
    , fromModuleToProject : ModuleKey -> Node ModuleName -> moduleContext -> projectContext
    , foldProjectContexts : projectContext -> projectContext -> projectContext
    }
    -> ProjectRuleSchema { schemaState | canAddModuleVisitor : (), withModuleContext : Required } projectContext moduleContext
    -> ProjectRuleSchema { schemaState | hasAtLeastOneVisitor : (), withModuleContext : Forbidden } projectContext moduleContext
withModuleContext functions (ProjectRuleSchema schema) =
    let
        moduleContextCreator : Context projectContext moduleContext
        moduleContextCreator =
            Context.init
                (\moduleKey metadata projectContext ->
                    functions.fromProjectToModule
                        moduleKey
                        (Metadata.moduleNameNode metadata)
                        projectContext
                )
                |> Context.withModuleKey
                |> Context.withMetadata
    in
    ProjectRuleSchema
        { schema
            | moduleContextCreator = Just moduleContextCreator
            , folder =
                Just
                    { fromModuleToProject =
                        Context.init (\moduleKey metadata moduleContext -> functions.fromModuleToProject moduleKey (Metadata.moduleNameNode metadata) moduleContext)
                            |> Context.withModuleKey
                            |> Context.withMetadata
                    , foldProjectContexts = functions.foldProjectContexts
                    }
        }


withContextFromImportedModules : ProjectRuleSchema schemaState projectContext moduleContext -> ProjectRuleSchema schemaState projectContext moduleContext
withContextFromImportedModules (ProjectRuleSchema schema) =
    ProjectRuleSchema { schema | traversalType = ImportedModulesFirst }


{-| Create a [`Rule`](#Rule) from a configured [`ModuleRuleSchema`](#ModuleRuleSchema).
-}
fromModuleRuleSchema : ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext -> Rule
fromModuleRuleSchema ((ModuleRuleSchema schema) as moduleVisitor) =
    let
        initialContext : moduleContext
        initialContext =
            case schema.initialModuleContext of
                Just initialModuleContext ->
                    initialModuleContext

                Nothing ->
                    Debug.todo "Define initial module context"

        --elmJsonVisitors : List (Maybe { elmJsonKey : ElmJsonKey, project : Elm.Project.Project } -> moduleContext -> ( List (Error {}), moduleContext ))
        --elmJsonVisitors =
        --    schema.elmJsonVisitors
        projectRule : ProjectRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext moduleContext
        projectRule =
            ProjectRuleSchema
                { name = schema.name
                , initialProjectContext = initialContext
                , elmJsonVisitors = [] -- List (Maybe { elmJsonKey : ElmJsonKey, project : Elm.Project.Project } -> projectContext -> ( List (Error {}), projectContext ))
                , readmeVisitors = [] -- (Maybe { readmeKey : ReadmeKey, content : String } -> projectContext -> ( List (Error {}), projectContext ))
                , dependenciesVisitors = [] -- (Dict String Review.Project.Dependency.Dependency -> projectContext -> ( List (Error {}), projectContext ))
                , moduleVisitors = [ removeExtensibleRecordTypeVariable (always moduleVisitor) ]
                , moduleContextCreator = Just (Context.init (always initialContext))
                , folder = Nothing

                -- TODO Jeroen Only allow to set it if there is a folder, but not several times
                , traversalType = AllModulesInParallel
                , finalEvaluationFns = []
                }
    in
    fromProjectRuleSchema projectRule


{-| This function that is supplied by the user will be stored in the `ProjectRuleSchema`,
but it contains an extensible record. This means that `ProjectRuleSchema` will
need an additional type variable for no useful value. Because we have full control
over the `ModuleRuleSchema` in this module, we can change the phantom type to be
whatever we want it to be, and we'll change it something that makes sense but
without the extensible record type variable.
-}
removeExtensibleRecordTypeVariable :
    (ModuleRuleSchema {} moduleContext -> ModuleRuleSchema { a | hasAtLeastOneVisitor : () } moduleContext)
    -> (ModuleRuleSchema {} moduleContext -> ModuleRuleSchema { hasAtLeastOneVisitor : () } moduleContext)
removeExtensibleRecordTypeVariable function =
    function >> (\(ModuleRuleSchema param) -> ModuleRuleSchema param)



--runModuleRule_New
--    (reverseVisitors_New moduleVisitor)
--    Nothing
--    |> Rule schema.name Exceptions.init
--fromProjectRuleSchema : ProjectRuleSchema { schemaState | hasAtLeastOneVisitor : () } projectContext moduleContext -> Rule
--fromProjectRuleSchema ((ProjectRuleSchema schema) as projectRuleSchema) =
--    Rule schema.name
--        Exceptions.init
--        (Review.Visitor.run (fromProjectRuleSchemaToRunnableProjectVisitor projectRuleSchema) Nothing)
--fromProjectRuleSchemaToRunnableProjectVisitor : ProjectRuleSchema schemaState projectContext moduleContext -> Review.Visitor.RunnableProjectVisitor projectContext moduleContext
--fromProjectRuleSchemaToRunnableProjectVisitor (ProjectRuleSchema schema) =
--    { name = schema.name
--    , initialProjectContext = schema.initialProjectContext
--    , elmJsonVisitors = List.reverse schema.elmJsonVisitors
--    , readmeVisitors = List.reverse schema.readmeVisitors
--    , dependenciesVisitors = List.reverse schema.dependenciesVisitors
--    , moduleVisitor = mergeModuleVisitors schema.name schema.moduleContextCreator schema.moduleVisitors
--    , folder = schema.folder
--
--    -- TODO Jeroen Only allow to set it if there is a folder, but not several times
--    , traversalType = schema.traversalType
--    , finalEvaluationFns = List.reverse schema.finalEvaluationFns
--    }


withElmJsonProjectVisitor :
    (Maybe { elmJsonKey : ElmJsonKey, project : Elm.Project.Project } -> projectContext -> ( List (Error {}), projectContext ))
    -> ProjectRuleSchema schemaState projectContext moduleContext
    -> ProjectRuleSchema { schemaState | hasAtLeastOneVisitor : () } projectContext moduleContext
withElmJsonProjectVisitor visitor (ProjectRuleSchema projectRuleSchema) =
    -- TODO BREAKING CHANGE, make elm.json mandatory
    -- TODO BREAKING CHANGE, Rename to withElmJsonVisitor
    ProjectRuleSchema { projectRuleSchema | elmJsonVisitors = visitor :: projectRuleSchema.elmJsonVisitors }


withReadmeProjectVisitor :
    (Maybe { readmeKey : ReadmeKey, content : String } -> projectContext -> ( List (Error {}), projectContext ))
    -> ProjectRuleSchema schemaState projectContext moduleContext
    -> ProjectRuleSchema { schemaState | hasAtLeastOneVisitor : () } projectContext moduleContext
withReadmeProjectVisitor visitor (ProjectRuleSchema projectRuleSchema) =
    -- TODO BREAKING CHANGE, Rename to withReadmeVisitor
    ProjectRuleSchema { projectRuleSchema | readmeVisitors = visitor :: projectRuleSchema.readmeVisitors }


withDependenciesProjectVisitor :
    (Dict String Review.Project.Dependency.Dependency -> projectContext -> ( List (Error {}), projectContext ))
    -> ProjectRuleSchema schemaState projectContext moduleContext
    -> ProjectRuleSchema { schemaState | hasAtLeastOneVisitor : () } projectContext moduleContext
withDependenciesProjectVisitor visitor (ProjectRuleSchema projectRuleSchema) =
    -- TODO BREAKING CHANGE, Rename to withDependenciesVisitor
    ProjectRuleSchema { projectRuleSchema | dependenciesVisitors = visitor :: projectRuleSchema.dependenciesVisitors }


withFinalProjectEvaluation :
    (projectContext -> List (Error { useErrorForModule : () }))
    -> ProjectRuleSchema schemaState projectContext moduleContext
    -> ProjectRuleSchema { schemaState | hasAtLeastOneVisitor : () } projectContext moduleContext
withFinalProjectEvaluation visitor (ProjectRuleSchema projectRuleSchema) =
    let
        removeErrorPhantomTypeFromEvaluation : (projectContext -> List (Error b)) -> (projectContext -> List (Error {}))
        removeErrorPhantomTypeFromEvaluation function projectContext =
            function projectContext
                |> List.map removeErrorPhantomType
    in
    ProjectRuleSchema { projectRuleSchema | finalEvaluationFns = removeErrorPhantomTypeFromEvaluation visitor :: projectRuleSchema.finalEvaluationFns }


fromProjectRuleSchema : ProjectRuleSchema { schemaState | hasAtLeastOneVisitor : () } projectContext moduleContext -> Rule
fromProjectRuleSchema ((ProjectRuleSchema schema) as projectRuleSchema) =
    Rule schema.name
        Exceptions.init
        (Review.Visitor.run (fromProjectRuleSchemaToRunnableProjectVisitor projectRuleSchema) Nothing)


fromProjectRuleSchemaToRunnableProjectVisitor : ProjectRuleSchema schemaState projectContext moduleContext -> Review.Visitor.RunnableProjectVisitor projectContext moduleContext
fromProjectRuleSchemaToRunnableProjectVisitor (ProjectRuleSchema schema) =
    { name = schema.name
    , initialProjectContext = schema.initialProjectContext
    , elmJsonVisitors = List.reverse schema.elmJsonVisitors
    , readmeVisitors = List.reverse schema.readmeVisitors
    , dependenciesVisitors = List.reverse schema.dependenciesVisitors
    , moduleVisitor = mergeModuleVisitors schema.initialProjectContext schema.moduleContextCreator schema.moduleVisitors
    , traversalAndFolder =
        case ( schema.traversalType, schema.folder ) of
            ( AllModulesInParallel, _ ) ->
                Review.Visitor.TraverseAllModulesInParallel schema.folder

            ( ImportedModulesFirst, Just folder ) ->
                Review.Visitor.TraverseImportedModulesFirst folder

            ( ImportedModulesFirst, Nothing ) ->
                -- TODO Jeroen Only allow to set it if there is a folder, but not several times
                Review.Visitor.TraverseAllModulesInParallel Nothing
    , finalEvaluationFns = List.reverse schema.finalEvaluationFns
    }


mergeModuleVisitors :
    projectContext
    -> Maybe (Context projectContext moduleContext)
    -> List (ModuleRuleSchema schemaState1 moduleContext -> ModuleRuleSchema schemaState2 moduleContext)
    -> Maybe ( Review.Visitor.RunnableModuleVisitor moduleContext, Context projectContext moduleContext )
mergeModuleVisitors initialProjectContext maybeModuleContextCreator visitors =
    case ( maybeModuleContextCreator, List.isEmpty visitors ) of
        ( Nothing, _ ) ->
            Nothing

        ( _, True ) ->
            Nothing

        ( Just moduleContextCreator, False ) ->
            let
                dummyAvailableData : Context.AvailableData
                dummyAvailableData =
                    { metadata = Metadata.create { moduleNameNode = Node.Node Range.emptyRange [] }
                    , moduleKey = ModuleKey "dummy"
                    }

                initialModuleContext : moduleContext
                initialModuleContext =
                    Context.apply dummyAvailableData moduleContextCreator initialProjectContext

                emptyModuleVisitor : ModuleRuleSchema schemaState moduleContext
                emptyModuleVisitor =
                    ModuleRuleSchema
                        { name = ""
                        , initialModuleContext = Just initialModuleContext
                        , moduleContextCreator = Context.init (always initialModuleContext)
                        , moduleDefinitionVisitors = []
                        , commentsVisitors = []
                        , importVisitors = []
                        , declarationListVisitors = []
                        , declarationVisitorsOnEnter = []
                        , declarationVisitorsOnExit = []
                        , expressionVisitorsOnEnter = []
                        , expressionVisitorsOnExit = []
                        , finalEvaluationFns = []
                        }
            in
            Just
                ( List.foldl
                    (\addVisitors (ModuleRuleSchema moduleVisitorSchema) ->
                        addVisitors (ModuleRuleSchema moduleVisitorSchema)
                    )
                    emptyModuleVisitor
                    visitors
                    |> fromModuleRuleSchemaToRunnableModuleVisitor
                , moduleContextCreator
                )


fromModuleRuleSchemaToRunnableModuleVisitor : ModuleRuleSchema schemaState moduleContext -> Review.Visitor.RunnableModuleVisitor moduleContext
fromModuleRuleSchemaToRunnableModuleVisitor (ModuleRuleSchema schema) =
    { moduleDefinitionVisitors = List.reverse schema.moduleDefinitionVisitors
    , commentsVisitors = List.reverse schema.commentsVisitors
    , importVisitors = List.reverse schema.importVisitors
    , declarationListVisitors = List.reverse schema.declarationListVisitors
    , declarationVisitorsOnEnter = List.reverse schema.declarationVisitorsOnEnter
    , declarationVisitorsOnExit = schema.declarationVisitorsOnExit
    , expressionVisitorsOnEnter = List.reverse schema.expressionVisitorsOnEnter
    , expressionVisitorsOnExit = schema.expressionVisitorsOnExit
    , finalEvaluationFns = List.reverse schema.finalEvaluationFns
    }


withSimpleModuleDefinitionVisitor : (Node Module -> List (Error {})) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withSimpleModuleDefinitionVisitor visitor schema =
    withModuleDefinitionVisitor (\node moduleContext -> ( visitor node, moduleContext )) schema


withModuleDefinitionVisitor : (Node Module -> moduleContext -> ( List (Error {}), moduleContext )) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withModuleDefinitionVisitor visitor (ModuleRuleSchema schema) =
    ModuleRuleSchema { schema | moduleDefinitionVisitors = visitor :: schema.moduleDefinitionVisitors }


withSimpleCommentsVisitor : (List (Node String) -> List (Error {})) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withSimpleCommentsVisitor visitor schema =
    withCommentsVisitor (\node moduleContext -> ( visitor node, moduleContext )) schema


withCommentsVisitor : (List (Node String) -> moduleContext -> ( List (Error {}), moduleContext )) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withCommentsVisitor visitor (ModuleRuleSchema schema) =
    ModuleRuleSchema { schema | commentsVisitors = visitor :: schema.commentsVisitors }


withSimpleImportVisitor : (Node Import -> List (Error {})) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withSimpleImportVisitor visitor schema =
    withImportVisitor (\node moduleContext -> ( visitor node, moduleContext )) schema


withImportVisitor : (Node Import -> moduleContext -> ( List (Error {}), moduleContext )) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withImportVisitor visitor (ModuleRuleSchema schema) =
    ModuleRuleSchema { schema | importVisitors = visitor :: schema.importVisitors }


withSimpleDeclarationVisitor : (Node Declaration -> List (Error {})) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withSimpleDeclarationVisitor visitor schema =
    withDeclarationEnterVisitor
        (\node moduleContext -> ( visitor node, moduleContext ))
        schema


withDeclarationVisitor : (Node Declaration -> Direction -> moduleContext -> ( List (Error {}), moduleContext )) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withDeclarationVisitor visitor (ModuleRuleSchema schema) =
    ModuleRuleSchema
        { schema
            | declarationVisitorsOnEnter = (\node ctx -> visitor node OnEnter ctx) :: schema.declarationVisitorsOnEnter
            , declarationVisitorsOnExit = (\node ctx -> visitor node OnExit ctx) :: schema.declarationVisitorsOnExit
        }


withDeclarationEnterVisitor : (Node Declaration -> moduleContext -> ( List (Error {}), moduleContext )) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withDeclarationEnterVisitor visitor (ModuleRuleSchema schema) =
    ModuleRuleSchema { schema | declarationVisitorsOnEnter = visitor :: schema.declarationVisitorsOnEnter }


withDeclarationExitVisitor : (Node Declaration -> moduleContext -> ( List (Error {}), moduleContext )) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withDeclarationExitVisitor visitor (ModuleRuleSchema schema) =
    ModuleRuleSchema { schema | declarationVisitorsOnExit = visitor :: schema.declarationVisitorsOnExit }


withDeclarationListVisitor : (List (Node Declaration) -> moduleContext -> ( List (Error {}), moduleContext )) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withDeclarationListVisitor visitor (ModuleRuleSchema schema) =
    ModuleRuleSchema { schema | declarationListVisitors = visitor :: schema.declarationListVisitors }


withSimpleExpressionVisitor : (Node Expression -> List (Error {})) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withSimpleExpressionVisitor visitor schema =
    withExpressionEnterVisitor
        (\node moduleContext -> ( visitor node, moduleContext ))
        schema


withExpressionVisitor : (Node Expression -> Direction -> moduleContext -> ( List (Error {}), moduleContext )) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withExpressionVisitor visitor (ModuleRuleSchema schema) =
    ModuleRuleSchema
        { schema
            | expressionVisitorsOnEnter = (\node ctx -> visitor node OnEnter ctx) :: schema.expressionVisitorsOnEnter
            , expressionVisitorsOnExit = (\node ctx -> visitor node OnExit ctx) :: schema.expressionVisitorsOnExit
        }


withExpressionEnterVisitor : (Node Expression -> moduleContext -> ( List (Error {}), moduleContext )) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withExpressionEnterVisitor visitor (ModuleRuleSchema schema) =
    ModuleRuleSchema { schema | expressionVisitorsOnEnter = visitor :: schema.expressionVisitorsOnEnter }


withExpressionExitVisitor : (Node Expression -> moduleContext -> ( List (Error {}), moduleContext )) -> ModuleRuleSchema schemaState moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withExpressionExitVisitor visitor (ModuleRuleSchema schema) =
    ModuleRuleSchema { schema | expressionVisitorsOnExit = visitor :: schema.expressionVisitorsOnExit }


withFinalModuleEvaluation : (moduleContext -> List (Error {})) -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext -> ModuleRuleSchema { schemaState | hasAtLeastOneVisitor : () } moduleContext
withFinalModuleEvaluation visitor (ModuleRuleSchema schema) =
    ModuleRuleSchema { schema | finalEvaluationFns = visitor :: schema.finalEvaluationFns }
