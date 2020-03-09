module NoUnused.CustomTypeConstructors exposing (rule)

{-| Forbid having unused custom type constructors in a file.


# Rule

@docs rule

-}

import Dict exposing (Dict)
import Elm.Syntax.Declaration as Declaration exposing (Declaration)
import Elm.Syntax.Exposing as Exposing exposing (Exposing, TopLevelExpose)
import Elm.Syntax.Expression as Expression exposing (Expression)
import Elm.Syntax.Module as Module exposing (Module)
import Elm.Syntax.Node as Node exposing (Node)
import Elm.Syntax.TypeAnnotation as TypeAnnotation exposing (TypeAnnotation)
import Review.Rule as Rule exposing (Direction, Error, Rule)
import Set exposing (Set)


{-| Forbid having unused custom type constructors in a file.

    config =
        [ NoUnused.CustomTypeConstructors.rule
        ]

Note that this does not report a constructor if it is exposed in the module, even
if it is not used anywhere in the project. For a more accurate detection of
unused constructors (and functions) across your project, you might want to check
out [elm-xref](https://github.com/zwilias/elm-xref). You may still want to use
this rule in your config so that you get notified of unused constructors earlier
in your editor, rather than when running your tests or [elm-xref](https://github.com/zwilias/elm-xref).


## Fail

    module A exposing (a)

    type MyType
        = UsedType
        | UnusedType -- Will get reported

    a =
        UsedType


## Success

    module A exposing (ExposedType(..))

    type MyType
        = UsedType

    a =
        UsedType

    type ExposedType
        = A
        | B
        | C

    -----------------------
    module A exposing (..)

    type ExposedType
        = A
        | B
        | C

-}
rule : Rule
rule =
    Rule.newModuleRuleSchema "NoUnused.CustomTypeConstructors" initialContext
        |> Rule.withModuleDefinitionVisitor moduleDefinitionVisitor
        |> Rule.withDeclarationListVisitor declarationListVisitor
        |> Rule.withDeclarationVisitor declarationVisitor
        |> Rule.withExpressionVisitor expressionVisitor
        |> Rule.withFinalModuleEvaluation finalEvaluation
        |> Rule.fromModuleRuleSchema


type alias Context =
    { exposedCustomTypesWithConstructors : Set String
    , exposesEverything : Bool
    , declaredTypesWithConstructors : Dict String (Node String)
    , usedFunctionOrValues : Set String
    , phantomVariables : List ( String, Int )
    }


initialContext : Context
initialContext =
    { exposedCustomTypesWithConstructors = Set.empty
    , exposesEverything = False
    , declaredTypesWithConstructors = Dict.empty
    , usedFunctionOrValues = Set.empty
    , phantomVariables = []
    }


error : Node String -> Error
error node =
    Rule.error
        { message = "Type constructor `" ++ Node.value node ++ "` is not used."
        , details =
            [ "This type constructor is never used. It might be handled everywhere it might appear, but there is no location where this value actually gets created."
            , "You should either use this value somewhere, or remove it at the location I pointed at."
            , "If you remove it, you may find that other pieces of code are never used, and can themselves be removed too. This could end up simplifying your code a lot."
            ]
        }
        (Node.range node)



-- MODULE DEFINITION VISITOR


moduleDefinitionVisitor : Node Module -> Context -> ( List nothing, Context )
moduleDefinitionVisitor moduleNode context =
    case Module.exposingList (Node.value moduleNode) of
        Exposing.All _ ->
            ( [], { context | exposesEverything = True } )

        Exposing.Explicit list ->
            let
                names : List String
                names =
                    List.filterMap
                        (\node ->
                            case Node.value node of
                                Exposing.TypeExpose { name, open } ->
                                    case open of
                                        Just _ ->
                                            Just name

                                        Nothing ->
                                            Nothing

                                _ ->
                                    Nothing
                        )
                        list
            in
            ( []
            , { context
                | exposedCustomTypesWithConstructors =
                    Set.union (Set.fromList names) context.exposedCustomTypesWithConstructors
              }
            )



-- DECLARATION LIST VISITOR


declarationListVisitor : List (Node Declaration) -> Context -> ( List nothing, Context )
declarationListVisitor nodes context =
    ( [], List.foldl register context nodes )


register : Node Declaration -> Context -> Context
register node context =
    case Node.value node of
        Declaration.CustomTypeDeclaration { name, generics, constructors } ->
            let
                nonPhantomVariables : Set String
                nonPhantomVariables =
                    constructors
                        |> List.concatMap (Node.value >> .arguments)
                        |> List.concatMap collectGenericsFromTypeAnnotation
                        |> Set.fromList

                phantomVariables : List ( String, Int )
                phantomVariables =
                    generics
                        |> List.map Node.value
                        |> List.indexedMap Tuple.pair
                        |> List.filter (\( _, genericName ) -> not <| Set.member genericName nonPhantomVariables)
                        |> List.map (\( indexOfPhantomVariable, _ ) -> ( Node.value name, indexOfPhantomVariable ))
            in
            { context | phantomVariables = phantomVariables ++ context.phantomVariables }

        _ ->
            context


collectGenericsFromTypeAnnotation : Node TypeAnnotation -> List String
collectGenericsFromTypeAnnotation node =
    case Node.value node of
        TypeAnnotation.FunctionTypeAnnotation a b ->
            collectGenericsFromTypeAnnotation a ++ collectGenericsFromTypeAnnotation b

        TypeAnnotation.Typed nameNode params ->
            List.concatMap collectGenericsFromTypeAnnotation params

        TypeAnnotation.Record list ->
            list
                |> List.concatMap (Node.value >> Tuple.second >> collectGenericsFromTypeAnnotation)

        TypeAnnotation.GenericRecord name list ->
            Node.value list
                |> List.concatMap (Node.value >> Tuple.second >> collectGenericsFromTypeAnnotation)

        TypeAnnotation.Tupled list ->
            List.concatMap collectGenericsFromTypeAnnotation list

        TypeAnnotation.GenericType var ->
            [ var ]

        TypeAnnotation.Unit ->
            []



-- DECLARATION VISITOR


declarationVisitor : Node Declaration -> Direction -> Context -> ( List nothing, Context )
declarationVisitor node direction context =
    case ( direction, Node.value node ) of
        ( Rule.OnEnter, Declaration.CustomTypeDeclaration { name, constructors } ) ->
            if Set.member (Node.value name) context.exposedCustomTypesWithConstructors then
                ( [], context )

            else
                let
                    newContext : Context
                    newContext =
                        List.foldl
                            (\constructor ctx ->
                                let
                                    nameNode : Node String
                                    nameNode =
                                        (Node.value constructor).name
                                in
                                { ctx
                                    | declaredTypesWithConstructors =
                                        Dict.insert
                                            (Node.value nameNode)
                                            nameNode
                                            ctx.declaredTypesWithConstructors
                                }
                            )
                            context
                            constructors
                in
                ( [], newContext )

        ( Rule.OnEnter, Declaration.FunctionDeclaration function ) ->
            -- TODO Now find the types that were in the stead of a phantom variable
            let
                foo =
                    Debug.log "" <|
                        case function.signature of
                            Just signature ->
                                signature
                                    |> Node.value
                                    |> .typeAnnotation
                                    |> collectXYZ

                            Nothing ->
                                []
            in
            --
            --     usedFunctionOrValues : Set String
            --     usedFunctionOrValues =
            --         List.foldl
            --             Set.insert
            --             context.usedFunctionOrValues
            --             namesUsedInTypeAnnotation
            -- in
            -- ( [], { context | usedFunctionOrValues = usedFunctionOrValues } )
            ( [], { context | usedFunctionOrValues = Set.union (Set.fromList foo) context.usedFunctionOrValues } )

        _ ->
            ( [], context )


collectXYZ : Node TypeAnnotation -> List String
collectXYZ node =
    case Node.value node of
        TypeAnnotation.FunctionTypeAnnotation a b ->
            collectXYZ a ++ collectXYZ b

        TypeAnnotation.Typed (Node.Node _ ( [], name )) params ->
            name :: List.concatMap collectXYZ params

        TypeAnnotation.Typed nameNode params ->
            List.concatMap collectXYZ params

        TypeAnnotation.Record list ->
            list
                |> List.concatMap (Node.value >> Tuple.second >> collectXYZ)

        TypeAnnotation.GenericRecord name list ->
            Node.value list
                |> List.concatMap (Node.value >> Tuple.second >> collectXYZ)

        TypeAnnotation.Tupled list ->
            List.concatMap collectXYZ list

        TypeAnnotation.GenericType var ->
            []

        TypeAnnotation.Unit ->
            []



-- EXPRESSION VISITOR


expressionVisitor : Node Expression -> Direction -> Context -> ( List nothing, Context )
expressionVisitor node direction context =
    if context.exposesEverything then
        ( [], context )

    else
        case ( direction, Node.value node ) of
            ( Rule.OnEnter, Expression.FunctionOrValue [] name ) ->
                ( [], { context | usedFunctionOrValues = Set.insert name context.usedFunctionOrValues } )

            _ ->
                ( [], context )



-- FINAL EVALUATION


finalEvaluation : Context -> List Error
finalEvaluation context =
    if context.exposesEverything then
        []

    else
        context.declaredTypesWithConstructors
            |> Dict.filter (\name _ -> not <| Set.member name context.usedFunctionOrValues)
            |> Dict.toList
            |> List.map (\( _, node ) -> error node)
