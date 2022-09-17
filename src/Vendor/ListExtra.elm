module Vendor.ListExtra exposing
    ( find, last
    , orderIndependentMap, orderIndependentAppend, orderIndependentConcatMap
    , orderIndependentMapAppend, orderIndependentConcat, orderIndependentConcatMapAppend, orderIndependentFilterMap
    , anyCombination
    )

{-| Functions taken from elm-community/list-extra.

These were used so that we wouldn't have dependency conflicts when
elm-community/list-extra would release a new major version.

This also includes a few custom functions


# List functions

@docs find, last

@docs orderIndependentMap, orderIndependentAppend, orderIndependentConcatMap
@docs orderIndependentMapAppend, orderIndependentConcat, orderIndependentConcatMapAppend, orderIndependentFilterMap

@docs anyCombination

-}


{-| Find the first element that satisfies a predicate and return
Just that element. If none match, return Nothing.
find (\\num -> num > 5) [2, 4, 6, 8] == Just 6
-}
find : (a -> Bool) -> List a -> Maybe a
find predicate list =
    case list of
        [] ->
            Nothing

        first :: rest ->
            if predicate first then
                Just first

            else
                find predicate rest


last : List a -> Maybe a
last items =
    case items of
        [] ->
            Nothing

        [ x ] ->
            Just x

        _ :: rest ->
            last rest



-- Not originally from elm-community/list-extra


{-| Version of List.map that doesn't care about order.
-}
orderIndependentMap : (a -> b) -> List a -> List b
orderIndependentMap fn list =
    List.foldl (\element acc -> fn element :: acc) [] list


{-| Version of List.append that doesn't care about order.
-}
orderIndependentAppend : List a -> List a -> List a
orderIndependentAppend left right =
    List.foldl (::) right left


{-| Version of "List.append (List.map fn left) right" that doesn't care about order.
-}
orderIndependentMapAppend : (a -> b) -> List a -> List b -> List b
orderIndependentMapAppend fn left right =
    List.foldl (\element acc -> fn element :: acc) right left


{-| Version of "(List.concatMap fn left) ++ right" that doesn't care about order.
-}
orderIndependentConcatMapAppend : (a -> List b) -> List a -> List b -> List b
orderIndependentConcatMapAppend fn left right =
    List.foldl (\item acc -> orderIndependentAppend (fn item) acc) right left


orderIndependentConcat : List (List a) -> List a
orderIndependentConcat list =
    case list of
        [] ->
            []

        firstElement :: rest ->
            List.foldl (\subList acc -> orderIndependentAppend subList acc) firstElement rest


orderIndependentConcatMap : (a -> List b) -> List a -> List b
orderIndependentConcatMap fn list =
    List.foldl (\item acc -> orderIndependentAppend (fn item) acc) [] list


orderIndependentFilterMap : (a -> Maybe b) -> List a -> List b
orderIndependentFilterMap fn list =
    orderIndependentFilterMapHelp fn list []


orderIndependentFilterMapHelp : (a -> Maybe b) -> List a -> List b -> List b
orderIndependentFilterMapHelp fn list acc =
    case list of
        [] ->
            acc

        a :: rest ->
            case fn a of
                Just b ->
                    orderIndependentFilterMapHelp fn rest (b :: acc)

                Nothing ->
                    orderIndependentFilterMapHelp fn rest acc


{-| Similar to List.any, but on any combination pair of the list.
-}
anyCombination : (a -> a -> Bool) -> List a -> Bool
anyCombination predicate xs =
    case xs of
        [] ->
            False

        x :: xs_ ->
            if List.any (\y -> predicate x y) xs_ then
                True

            else
                anyCombination predicate xs_
