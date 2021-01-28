module Review.Type.Binop exposing
    ( Binop
    , name, tipe, documentation, associativity, precedence, associatedFunction
    , create
    )

{-| Represents binary operations defined in modules.

@docs Binop


# Access

@docs name, tipe, documentation, associativity, precedence, associatedFunction


# Creation

@docs create

-}

import Elm.Docs
import Review.Internal.Binop
import Review.Type as Type



-- TODO Expose module, but hide implementation and type inside an "Internal" module


type alias Binop =
    Review.Internal.Binop.Binop


{-| Create a new type binary operation.
-}
create :
    { name : String
    , associatedFunction : Maybe String
    , documentation : Maybe String
    , tipe : Maybe Type.Type
    , associativity : Elm.Docs.Associativity
    , precedence : Int
    }
    -> Binop
create =
    Review.Internal.Binop.create


{-| Get the name of a binary operation.

    infix left  6 (+)  = add
    -> "+"

-}
name : Binop -> String
name =
    Review.Internal.Binop.name


{-| Get the name of a binary operation. For the `+` operator, that would be `+`.

    infix left  6 (+)  = add
    -> "add"

-}
associatedFunction : Binop -> Maybe String
associatedFunction =
    Review.Internal.Binop.associatedFunction


documentation : Binop -> Maybe String
documentation =
    Review.Internal.Binop.documentation


tipe : Binop -> Maybe Type.Type
tipe =
    Review.Internal.Binop.tipe


associativity : Binop -> Elm.Docs.Associativity
associativity =
    Review.Internal.Binop.associativity


precedence : Binop -> Int
precedence =
    Review.Internal.Binop.precedence
