/// 语法树节点定义。
///
/// 全部节点都带 1 起始的行列号，运行时出错时可以把位置指到具体表达式上。
abstract class Node {
  Node(this.line, this.column);

  final int line;
  final int column;
}

// ===========================================================================
// 语句
// ===========================================================================

class Program extends Node {
  Program(this.body) : super(1, 1);

  final List<Stmt> body;
}

abstract class Stmt extends Node {
  Stmt(super.line, super.column);
}

class EmptyStmt extends Stmt {
  EmptyStmt(super.line, super.column);
}

class BlockStmt extends Stmt {
  BlockStmt(this.body, super.line, super.column);

  final List<Stmt> body;
}

/// var / let / const
class VarDeclStmt extends Stmt {
  VarDeclStmt(this.kind, this.decls, super.line, super.column);

  /// 'var' | 'let' | 'const'
  final String kind;
  final List<VarDeclarator> decls;
}

class VarDeclarator extends Node {
  VarDeclarator(this.name, this.init, super.line, super.column);

  final String name;
  final Expr? init;
}

class Param extends Node {
  Param(
    this.name, {
    this.defaultValue,
    this.rest = false,
    required int line,
    required int column,
  }) : super(line, column);

  final String name;
  final Expr? defaultValue;
  final bool rest;
}

class FuncDecl extends Stmt {
  FuncDecl(this.name, this.params, this.body, super.line, super.column);

  final String name;
  final List<Param> params;
  final List<Stmt> body;
}

class ReturnStmt extends Stmt {
  ReturnStmt(this.value, super.line, super.column);

  final Expr? value;
}

class IfStmt extends Stmt {
  IfStmt(this.test, this.consequent, this.alternate, super.line, super.column);

  final Expr test;
  final Stmt consequent;
  final Stmt? alternate;
}

class ForStmt extends Stmt {
  ForStmt(this.init, this.test, this.update, this.body, super.line, super.column);

  final Node? init;
  final Expr? test;
  final Expr? update;
  final Stmt body;
}

class ForInStmt extends Stmt {
  ForInStmt({
    required this.declKind,
    required this.left,
    required this.isOf,
    required this.right,
    required this.body,
    required int line,
    required int column,
  }) : super(line, column);

  /// 'var' | 'let' | 'const'，或 null（`for (k in obj)`）
  final String? declKind;
  final Expr left;
  final bool isOf;
  final Expr right;
  final Stmt body;
}

class WhileStmt extends Stmt {
  WhileStmt(this.test, this.body, super.line, super.column);

  final Expr test;
  final Stmt body;
}

class DoWhileStmt extends Stmt {
  DoWhileStmt(this.body, this.test, super.line, super.column);

  final Stmt body;
  final Expr test;
}

class SwitchCase extends Node {
  SwitchCase(this.test, this.body, super.line, super.column);

  /// null 表示 default。
  final Expr? test;
  final List<Stmt> body;
}

class SwitchStmt extends Stmt {
  SwitchStmt(this.discriminant, this.cases, super.line, super.column);

  final Expr discriminant;
  final List<SwitchCase> cases;
}

class TryStmt extends Stmt {
  TryStmt({
    required this.block,
    this.catchParam,
    this.catchBlock,
    this.finallyBlock,
    required int line,
    required int column,
  }) : super(line, column);

  final BlockStmt block;
  final String? catchParam;
  final BlockStmt? catchBlock;
  final BlockStmt? finallyBlock;
}

class ThrowStmt extends Stmt {
  ThrowStmt(this.value, super.line, super.column);

  final Expr value;
}

class BreakStmt extends Stmt {
  BreakStmt(this.label, super.line, super.column);

  final String? label;
}

class ContinueStmt extends Stmt {
  ContinueStmt(this.label, super.line, super.column);

  final String? label;
}

class ExprStmt extends Stmt {
  ExprStmt(this.expr, super.line, super.column);

  final Expr expr;
}

class LabeledStmt extends Stmt {
  LabeledStmt(this.label, this.body, super.line, super.column);

  final String label;
  final Stmt body;
}

// ===========================================================================
// 表达式
// ===========================================================================

abstract class Expr extends Node {
  Expr(super.line, super.column);
}

class NumLit extends Expr {
  NumLit(this.value, super.line, super.column);

  final num value;
}

class StrLit extends Expr {
  StrLit(this.value, super.line, super.column);

  final String value;
}

class BoolLit extends Expr {
  BoolLit(this.value, super.line, super.column);

  final bool value;
}

class NullLit extends Expr {
  NullLit(super.line, super.column);
}

/// 模板字符串：parts 里是 String 或 Expr。
class TemplateLit extends Expr {
  TemplateLit(this.parts, super.line, super.column);

  final List<Object> parts;
}

class RegexLit extends Expr {
  RegexLit(this.pattern, this.flags, super.line, super.column);

  final String pattern;
  final String flags;
}

class ArrayLit extends Expr {
  ArrayLit(this.elements, super.line, super.column);

  /// null 表示数组空位（`[1, , 3]`）。
  final List<Expr?> elements;
}

class ObjProp extends Node {
  ObjProp({
    this.key,
    this.computedKey,
    required this.value,
    required int line,
    required int column,
  }) : super(line, column);

  final String? key;
  final Expr? computedKey;
  final Expr value;
}

class ObjectLit extends Expr {
  ObjectLit(this.props, super.line, super.column);

  final List<ObjProp> props;
}

class SpreadExpr extends Expr {
  SpreadExpr(this.argument, super.line, super.column);

  final Expr argument;
}

class Ident extends Expr {
  Ident(this.name, super.line, super.column);

  final String name;
}

class ThisExpr extends Expr {
  ThisExpr(super.line, super.column);
}

class MemberExpr extends Expr {
  MemberExpr(
    this.object,
    this.property, {
    required this.computed,
    required this.optional,
    required int line,
    required int column,
  }) : super(line, column);

  final Expr object;

  /// computed 时是 Expr；否则是 String。
  final Object property;
  final bool computed;
  final bool optional;
}

class CallExpr extends Expr {
  CallExpr(
    this.callee,
    this.args, {
    required this.optional,
    required int line,
    required int column,
  }) : super(line, column);

  final Expr callee;
  final List<Expr> args;
  final bool optional;
}

class NewExpr extends Expr {
  NewExpr(this.callee, this.args, super.line, super.column);

  final Expr callee;
  final List<Expr> args;
}

class UnaryExpr extends Expr {
  UnaryExpr(this.op, this.argument, super.line, super.column);

  final String op;
  final Expr argument;
}

class UpdateExpr extends Expr {
  UpdateExpr(this.op, this.argument, {required this.prefix, required int line, required int column})
      : super(line, column);

  final String op;
  final Expr argument;
  final bool prefix;
}

class BinaryExpr extends Expr {
  BinaryExpr(this.op, this.left, this.right, super.line, super.column);

  final String op;
  final Expr left;
  final Expr right;
}

class LogicalExpr extends Expr {
  LogicalExpr(this.op, this.left, this.right, super.line, super.column);

  final String op;
  final Expr left;
  final Expr right;
}

class AssignExpr extends Expr {
  AssignExpr(this.op, this.target, this.value, super.line, super.column);

  final String op;
  final Expr target;
  final Expr value;
}

class ConditionalExpr extends Expr {
  ConditionalExpr(this.test, this.consequent, this.alternate, super.line, super.column);

  final Expr test;
  final Expr consequent;
  final Expr alternate;
}

class SequenceExpr extends Expr {
  SequenceExpr(this.exprs, super.line, super.column);

  final List<Expr> exprs;
}

class FuncExpr extends Expr {
  FuncExpr(this.name, this.params, this.body, super.line, super.column);

  final String? name;
  final List<Param> params;
  final List<Stmt> body;
}

class ArrowFn extends Expr {
  ArrowFn(this.params, this.body, this.isExpressionBody, super.line, super.column);

  final List<Param> params;

  /// expression body 时是 [Expr]，否则是 `List<Stmt>`。
  final Object body;
  final bool isExpressionBody;
}
