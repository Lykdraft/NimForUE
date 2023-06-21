import std/[json, sugar, macros, genasts, options, sequtils, strutils, strformat]
when defined nuevm:
  import exposed 
import runtimefield
import ../utils/[utils, ueutils]
import ../codegen/[models, modelconstructor, uebindcore]

when not defined(log):
  proc log(str: string) = echo str

#TODO change fn with UEFunc so I can pass it directly from the bindings. 
proc ueBindImpl*(fn: UEField, selfParam: Option[UEField], kind: UECallKind) : NimNode = 
  assert fn.kind == uefFunction
  let isStatic = selfParam.isNone
  let clsName = fn.typeName   
  let selfAssign = 
    if isStatic: newEmptyNode() 
    else: 
      genAst(firstParam = ident selfParam.get.name):
        call.self = cast[int](firstParam)
  
  let returnType = fn.signature.first(isReturnParam).map(x=>getTypeNodeFromUProp(x, false)).get(ident "void")

  let uFunc = UEFunc(name: fn.name, className:clsName)
  let paramsAsExpr = 
      fn.signature      
        .filterIt(not it.isReturnParam())
        .mapIt(it.name.firstToLow.ueNameToNimName())
        .mapIt(nnkExprColonExpr.newTree(ident it, ident it)) #(arg: arg, arg2: arg2, etc.)
                 
  let rtFieldVal = 
    case kind:
      of uecFunc:
        nnkTupleConstr.newTree(paramsAsExpr)      
      of uecGetProp:
        nnkTupleConstr.newTree(nnkExprColonExpr.newTree(
          ident fn.name.firstToLow.ueNameToNimName(),
          nnkCall.newTree(ident "default", returnType)
        ))
      of uecSetProp: 
        nnkTupleConstr.newTree(nnkExprColonExpr.newTree(
          ident fn.name.firstToLow.ueNameToNimName(),
          ident fn.signature[0].name #val
        ))
  let call = 
   case kind:
    of uecFunc:
      if isStatic:
        UECall(kind: uecFunc,fn: uFunc)
      else:
        UECall(kind: uecFunc, fn: uFunc)
    else:    
      UECall(kind: kind, clsName: clsName)    
  
  let fnName = 
    case kind:
    of uecFunc, uecgetProp: ident fn.name.firstToLow()
    else: 
      genAst(fnName=ident fn.name.firstToLow()):
        `fnName=`  

  let returnBlock = 
    if fn.doesReturn():
      if fn.getReturnProp.get.name.endsWith("Ptr"):
        genAst(returnType):
          return castIntToPtr returnType(returnVal.get.runtimeFieldTo(int))
      else:
        genAst(returnType):
          return returnVal.get.runtimeFieldTo(returnType)
    else: newEmptyNode()


  result = 
    genAst(fnName, selfAssign, returnBlock, callData=newLit call, rtFieldVal):
      proc fnName() =         
        var call {.inject.} = callData
        call.value = rtFieldVal.toRuntimeField()
        selfAssign
        let returnVal {.used, inject.} = uCall(call)
        returnBlock
  result.params = genFormalParamsInFunctionSignature(fn.getFakeUETypeFromFunc(), fn)
  

proc prepareUEFieldFuncFrom(fn:NimNode): (UEField, UEField) = 
  let clsName = 
    if fn.params.len > 1:
      fn.params.filterIt(it.kind == nnkIdentDefs)[0][1].strVal().removeLastLettersIfPtr()
    else: 
      ""
  let clsFieldMb = 
    if clsName!="": some makeFieldAsUProp("self", clsName & "Ptr", clsName) 
    else: none[UEField]()
  
  var (ufunc, selfParam) = ufuncFieldFromNimNode(fn, clsFieldMb, clsName)  
  ufunc.signature = ufunc.signature[1..^1]
  (ufunc, selfParam)

macro uebind*(fn:untyped) : untyped = 
  #Remove the first arg, which is the self param
  let (ufunc, selfParam) = prepareUEFieldFuncFrom(fn)
  result = ueBindImpl(ufunc, some selfParam, uecFunc)
  # log "================================================================"
  # log repr result
  
macro uegetter*(getter:untyped): untyped = 
  var (ufunc, selfParam) = prepareUEFieldFuncFrom(getter) 
  ufunc.signature[0].isReturn = true
  result = ueBindImpl(ufunc,some selfParam, uecGetProp) 
  # log "================================================================"
  # log &"\n{repr result}"
  # log &"\n{treeRepr result}"


macro uesetter*(setter:untyped): untyped = 
  var (ufunc, selfParam) = prepareUEFieldFuncFrom(setter) 
  # log "usetter"
  log $ufunc
  result = ueBindImpl(ufunc, some selfParam, uecSetProp) 
  # log &"\n{repr result}"
  # log &"\n{treeRepr result}"

# macro uebindStatic*(clsName : static string = "", fn:untyped) : untyped = ueBindImpl(clsName, fn, uecFunc)

#Move into utils
proc removeLastLettersIfPtr*(str:string) : string = 
    if str.endsWith("Ptr"): str.substr(0, str.len()-4) else: str


func isAllowedField*(field:UEField) : bool = 
  const skipTypes = ["TScriptInterface", "TMap", "TSet"]
  result = not skipTypes.mapIt(field.uePropType.contains(it)).foldl(a or b, false) and
    not field.isOutParam()
  if not result:
    debugEcho &"[VM Bindings] Skipping field in {field.typeName} {field.name}: {field.uePropType} "


proc genUCalls*(typeDef : UEType) : NimNode = 
  #returns a list with all functions and props for a given type
  assert typeDef.kind == uetClass
  result = nnkStmtList.newTree()
  for field in typeDef.fields:
    let firstParam = some makeFieldAsUProp("self", typeDef.name & "Ptr", typeDef.name)
    case field.kind:
      of uefProp:
        if not isAllowedField(field): continue
        let propName = field.name.firstToLow.ueNameToNimName()                
        let getterFn = makeFieldAsUFun(propName, @[makeFieldAsUPropReturnParam("toReturn", field.uePropType, typeDef.name)], typeDef.name)
        let setterFn = makeFieldAsUFun(field.name.firstToLow(), @[makeFieldAsUPropParam("value", field.uePropType, typeDef.name)], typeDef.name) 
        result.add(ueBindImpl(getterFn, firstParam, uecGetProp))
        result.add(ueBindImpl(setterFn, firstParam, uecSetProp))
      of uefFunction:
        let isAllowed = field.signature.map(isAllowedField).foldl(a and b, true)
        if not isAllowed: continue
        if field.isStatic:
          result.add(ueBindImpl(field, none(UEField), uecFunc))
        else:
          result.add(ueBindImpl(field, firstParam, uecFunc))
      else: continue


proc ueBorrowImpl(clsName : string, fn: NimNode) : NimNode = 
  #TODO: integrate UEField approach 
  let argsWithFirstType =
    fn.params
    .filterIt(it.kind == nnkIdentDefs)
  
  let isStatic = clsName!=""

  let args = 
    if isStatic: argsWithFirstType
    else: argsWithFirstType[1..^1] #Remove the first arg, which is the self param
 
  let clsNameLit = 
    (if isStatic: clsName
    else: argsWithFirstType[0][1].strVal().removeLastLettersIfPtr()).removeFirstLetter()
  
  let classTypePtr = if isStatic: newEmptyNode() else: ident (argsWithFirstType[0][1].strVal())
  let classType = ident classTypePtr.strVal().removeLastLettersIfPtr() 

  let returnTypeLit = if fn.params[0].kind == nnkEmpty: "void" else: fn.params[0].repr()
  let returnType = fn.params[0]

  let fnBody = fn.body
  let fnName = fn.name
  let fnNameLit = fn.name.strVal()
  let fnVmName = ident fnNameLit & "VmImpl"
  let fnVmNameLit = fnNameLit & "VmImpl"

  func injectedArg(arg:NimNode, idx:int) : NimNode = 
    let argName = arg[0]
    let argNameLit = argName.strVal()
    let argType = arg[1]
    genAst(argName, argNameLit, argType):
      let argName {.inject.} = callInfo.value[argNameLit].runtimeFieldTo(argType)
  
  let injectedArgs = nnkStmtList.newTree(args.mapi(injectedArg))

  let vmFn = 
    genAst(funName=fnName, fnNameLit, fnVmName, fnVmNameLit, fnBody, classType, clsNameLit, returnType, returnTypeLit, injectedArgs, isStatic):
      setupBorrow(UEBorrowInfo(fnName:fnNameLit, className:clsNameLit))
      proc fnVmName*(callInfo{.inject.}:UECall) : RuntimeField = 
        injectedArgs 
        when not isStatic:
          let self {.inject.} = castIntToPtr[classType](callInfo.self)
        when returnTypeLit == "void":
          fnBody
          RuntimeField() #no return
        else:
          let returnVal {.inject.} : returnType = fnBody
          returnVal.toRuntimeField()

  let (ufunc, selfParam) = prepareUEFieldFuncFrom(fn)
  let bindFn = ueBindImpl(ufunc, some selfParam, uecFunc)
  result = nnkStmtList.newTree(bindFn, vmFn)
  

macro ueborrow*(fn:untyped) : untyped = ueBorrowImpl("", fn)
macro ueborrowStatic*(clsName : static string, fn:untyped) : untyped = ueBorrowImpl(clsName, fn)





macro ddumpTree*(x: untyped) = 
  log treeRepr x