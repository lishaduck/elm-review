module Review.Project.Valid exposing
    ( ValidProject
    , addParsedModule
    , addReadme
    , dependencies
    , directDependencies
    , elmJson
    , getModuleByPath
    , moduleGraph
    , moduleZipper
    , modules
    , parse
    , projectCache
    , readme
    , toRegularProject
    , updateProjectCache
    )

import Dict exposing (Dict)
import Elm.Package
import Elm.Project
import Elm.Syntax.File
import Elm.Syntax.Module
import Elm.Syntax.ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node
import Path
import Review.ImportCycle as ImportCycle
import Review.Project.Dependency exposing (Dependency)
import Review.Project.Internal exposing (Project(..))
import Review.Project.InvalidProjectError as InvalidProjectError exposing (InvalidProjectError)
import Review.Project.ProjectCache exposing (DataCache)
import Review.Project.ProjectModule exposing (ProjectModule)
import Set exposing (Set)
import Vendor.Graph as Graph exposing (Graph)
import Vendor.Zipper as Zipper exposing (Zipper)


type ValidProject
    = ValidProject ValidProjectData


type alias ValidProjectData =
    { modules : Dict String ProjectModule
    , elmJson : Maybe { path : String, raw : String, project : Elm.Project.Project }
    , readme : Maybe { path : String, content : String }
    , dependencies : Dict String Dependency
    , moduleGraph : Maybe (Graph ModuleName ())
    , sourceDirectories : List String
    , projectCache : DataCache
    , sortedModules : List (Graph.NodeContext ModuleName ())
    }


toRegularProject : ValidProject -> Project
toRegularProject (ValidProject validProject) =
    Project
        { modules = validProject.modules
        , modulesThatFailedToParse = []
        , elmJson = validProject.elmJson
        , readme = validProject.readme
        , dependencies = validProject.dependencies
        , moduleGraph = validProject.moduleGraph
        , sourceDirectories = validProject.sourceDirectories
        , dataCache = validProject.projectCache
        }


parse : Project -> Result InvalidProjectError ( ValidProject, Zipper (Graph.NodeContext ModuleName ()) )
parse ((Project p) as project) =
    if not (List.isEmpty p.modulesThatFailedToParse) then
        Err (InvalidProjectError.SomeModulesFailedToParse (List.map .path p.modulesThatFailedToParse))

    else
        let
            projectModules : List ProjectModule
            projectModules =
                Dict.values p.modules
        in
        if List.isEmpty projectModules then
            Err InvalidProjectError.NoModulesError

        else
            case duplicateModuleNames Dict.empty projectModules of
                Just duplicate ->
                    Err (InvalidProjectError.DuplicateModuleNames duplicate)

                Nothing ->
                    let
                        graph : Graph ModuleName ()
                        graph =
                            buildModuleGraph projectModules
                    in
                    case Graph.checkAcyclic graph of
                        Err edge ->
                            ImportCycle.findCycle graph edge
                                |> List.reverse
                                |> InvalidProjectError.ImportCycleError
                                |> Err

                        Ok acyclicGraph ->
                            case Zipper.fromList (Graph.topologicalSort acyclicGraph) of
                                Nothing ->
                                    Err InvalidProjectError.NoModulesError

                                Just zipper ->
                                    Ok ( fromProjectAndGraph acyclicGraph project, zipper )


{-| This is unsafe because we assume that there are some modules. We do check for this earlier in the exposed functions.
-}
unsafeCreateZipper : List a -> Zipper a
unsafeCreateZipper sortedModules =
    case Zipper.fromList sortedModules of
        Just zipper ->
            zipper

        Nothing ->
            unsafeCreateZipper sortedModules


fromProjectAndGraph : Graph.AcyclicGraph ModuleName () -> Project -> ValidProject
fromProjectAndGraph acyclicGraph (Project project) =
    ValidProject
        { modules = project.modules
        , elmJson = project.elmJson
        , readme = project.readme
        , dependencies = project.dependencies
        , moduleGraph = project.moduleGraph
        , sourceDirectories = project.sourceDirectories
        , projectCache = project.dataCache
        , sortedModules = Graph.topologicalSort acyclicGraph
        }


duplicateModuleNames : Dict ModuleName String -> List ProjectModule -> Maybe { moduleName : ModuleName, paths : List String }
duplicateModuleNames visitedModules projectModules =
    case projectModules of
        [] ->
            Nothing

        projectModule :: restOfModules ->
            let
                moduleName : ModuleName
                moduleName =
                    getModuleName projectModule
            in
            case Dict.get moduleName visitedModules of
                Nothing ->
                    duplicateModuleNames
                        (Dict.insert moduleName projectModule.path visitedModules)
                        restOfModules

                Just path ->
                    Just
                        { moduleName = moduleName
                        , paths =
                            path
                                :: projectModule.path
                                :: (restOfModules
                                        |> List.filter (\p -> getModuleName p == moduleName)
                                        |> List.map .path
                                   )
                        }


buildModuleGraph : List ProjectModule -> Graph ModuleName ()
buildModuleGraph mods =
    let
        moduleIds : Dict ModuleName Int
        moduleIds =
            mods
                |> List.indexedMap Tuple.pair
                |> List.foldl
                    (\( index, module_ ) dict ->
                        Dict.insert
                            (getModuleName module_)
                            index
                            dict
                    )
                    Dict.empty

        getModuleId : ModuleName -> Int
        getModuleId moduleName =
            case Dict.get moduleName moduleIds of
                Just moduleId ->
                    moduleId

                Nothing ->
                    getModuleId moduleName

        ( nodes, edges ) =
            mods
                |> List.foldl
                    (\module_ ( resNodes, resEdges ) ->
                        let
                            ( moduleNode, modulesEdges ) =
                                nodesAndEdges
                                    (\moduleName -> Dict.get moduleName moduleIds)
                                    module_
                                    (getModuleId <| getModuleName module_)
                        in
                        ( moduleNode :: resNodes, List.concat [ modulesEdges, resEdges ] )
                    )
                    ( [], [] )
    in
    Graph.fromNodesAndEdges nodes edges


nodesAndEdges : (ModuleName -> Maybe Int) -> ProjectModule -> Int -> ( Graph.Node ModuleName, List (Graph.Edge ()) )
nodesAndEdges getModuleId module_ moduleId =
    let
        moduleName : ModuleName
        moduleName =
            getModuleName module_
    in
    ( Graph.Node moduleId moduleName
    , importedModules module_
        |> List.filterMap getModuleId
        |> List.map
            (\importedModuleId ->
                Graph.Edge importedModuleId moduleId ()
            )
    )


importedModules : ProjectModule -> List ModuleName
importedModules module_ =
    module_.ast.imports
        |> List.map (Node.value >> .moduleName >> Node.value)


getModuleName : ProjectModule -> ModuleName
getModuleName module_ =
    module_.ast.moduleDefinition
        |> Node.value
        |> Elm.Syntax.Module.moduleName



-- ACCESSORS


elmJson : ValidProject -> Maybe { path : String, raw : String, project : Elm.Project.Project }
elmJson (ValidProject project) =
    project.elmJson


readme : ValidProject -> Maybe { path : String, content : String }
readme (ValidProject project) =
    project.readme


dependencies : ValidProject -> Dict String Dependency
dependencies (ValidProject project) =
    project.dependencies


{-| Get the direct [dependencies](./Review-Project-Dependency#Dependency) of the project.
-}
directDependencies : ValidProject -> Dict String Dependency
directDependencies (ValidProject project) =
    -- TODO Compute this in `parse` and store it in `ValidProject`
    case Maybe.map .project project.elmJson of
        Just (Elm.Project.Application { depsDirect, testDepsDirect }) ->
            let
                allDeps : List String
                allDeps =
                    List.map (\( name, _ ) -> Elm.Package.toString name) (depsDirect ++ testDepsDirect)
            in
            Dict.filter (\depName _ -> List.member depName allDeps) project.dependencies

        Just (Elm.Project.Package { deps, testDeps }) ->
            let
                allDeps : List String
                allDeps =
                    List.map (\( name, _ ) -> Elm.Package.toString name) (deps ++ testDeps)
            in
            Dict.filter (\depName _ -> List.member depName allDeps) project.dependencies

        Nothing ->
            project.dependencies


moduleGraph : ValidProject -> Graph ModuleName ()
moduleGraph (ValidProject project) =
    -- TODO Compute this in `parse` and store it in `ValidProject`
    case project.moduleGraph of
        Just graph ->
            graph

        Nothing ->
            buildModuleGraph (Dict.values project.modules)


{-| Get the list of modules in the project.
-}
modules : ValidProject -> List ProjectModule
modules (ValidProject project) =
    Dict.values project.modules


getModuleByPath : String -> ValidProject -> Maybe ProjectModule
getModuleByPath path (ValidProject project) =
    Dict.get path project.modules


projectCache : ValidProject -> DataCache
projectCache (ValidProject project) =
    project.projectCache


moduleZipper : ValidProject -> Zipper (Graph.NodeContext ModuleName ())
moduleZipper (ValidProject project) =
    unsafeCreateZipper project.sortedModules


updateProjectCache : DataCache -> ValidProject -> ValidProject
updateProjectCache projectCache_ (ValidProject project) =
    ValidProject { project | projectCache = projectCache_ }


{-| Add an already parsed module to the project. This module will then be analyzed by the rules.
-}
addParsedModule : { path : String, source : String, ast : Elm.Syntax.File.File } -> ValidProject -> Maybe ValidProject
addParsedModule { path, source, ast } (ValidProject project) =
    let
        osAgnosticPath : String
        osAgnosticPath =
            Path.makeOSAgnostic path

        module_ : ProjectModule
        module_ =
            { path = path
            , source = source
            , ast = ast
            , isInSourceDirectories = List.any (\dir -> String.startsWith (Path.makeOSAgnostic dir) osAgnosticPath) project.sourceDirectories
            }
    in
    case Dict.get path project.modules of
        Just existingModule ->
            if getModuleName existingModule == getModuleName module_ then
                if importedModulesSet existingModule.ast == importedModulesSet ast then
                    -- Imports haven't changed, we don't need to recompute the zipper or the graph
                    Just (ValidProject { project | modules = Dict.insert path (Review.Project.Internal.sanitizeModule module_) project.modules })

                else
                    -- Imports have changed, we need to recompute the zipper
                    -- TODO
                    Just (ValidProject { project | modules = Dict.insert path (Review.Project.Internal.sanitizeModule module_) project.modules })

            else
                -- If the path has not changed but the module name has, then the fix necessarily introduced a compilation error
                Nothing

        Nothing ->
            -- We don't support adding new files at the moment.
            Nothing


importedModulesSet : Elm.Syntax.File.File -> Set ModuleName
importedModulesSet ast =
    -- TODO Remove modules from dependencies
    List.foldl
        (\import_ set ->
            Set.insert (Node.value (Node.value import_).moduleName) set
        )
        Set.empty
        ast.imports


{-| Add the content of the `README.md` file to the project, making it
available for rules to access using
[`Review.Rule.withReadmeModuleVisitor`](./Review-Rule#withReadmeModuleVisitor) and
[`Review.Rule.withReadmeProjectVisitor`](./Review-Rule#withReadmeProjectVisitor).
-}
addReadme : { path : String, content : String } -> ValidProject -> ValidProject
addReadme readme_ (ValidProject project) =
    ValidProject { project | readme = Just readme_ }
