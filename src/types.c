#include "types.h"

const char *ty_name(TyKind t) {
  switch (t) {
    case TY_UNKNOWN: return "unknown";
    case TY_VOID:    return "void";
    case TY_NIL:     return "nil";
    case TY_INT:     return "int";
    case TY_FLOAT:   return "float";
    case TY_STRING:  return "string";
    case TY_SYMBOL:  return "symbol";
    case TY_BOOL:    return "bool";
    case TY_RANGE:   return "range";
    case TY_INT_ARRAY:   return "int_array";
    case TY_FLOAT_ARRAY: return "float_array";
    case TY_STR_ARRAY:   return "str_array";
    case TY_POLY_ARRAY:  return "poly_array";
    case TY_POLY:    return "poly";
  }
  return "?";
}

int ty_is_numeric(TyKind t) { return t == TY_INT || t == TY_FLOAT; }
int ty_is_array(TyKind t) {
  return t == TY_INT_ARRAY || t == TY_FLOAT_ARRAY ||
         t == TY_STR_ARRAY || t == TY_POLY_ARRAY;
}
TyKind ty_array_of(TyKind elem) {
  switch (elem) {
    case TY_INT:    return TY_INT_ARRAY;
    case TY_FLOAT:  return TY_FLOAT_ARRAY;
    case TY_STRING: return TY_STR_ARRAY;
    default:        return TY_POLY_ARRAY;
  }
}
TyKind ty_array_elem(TyKind arr) {
  switch (arr) {
    case TY_INT_ARRAY:   return TY_INT;
    case TY_FLOAT_ARRAY: return TY_FLOAT;
    case TY_STR_ARRAY:   return TY_STRING;
    default:             return TY_POLY;
  }
}

TyKind ty_unify(TyKind a, TyKind b) {
  if (a == b) return a;
  if (a == TY_UNKNOWN) return b;
  if (b == TY_UNKNOWN) return a;
  return TY_POLY;
}
