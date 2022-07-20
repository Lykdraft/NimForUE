include ../unreal/prelude
include ../utils/utils
import std/[sugar, macros, algorithm, strutils, strformat, genasts, sequtils, options]
import nuemacrocache
import uemeta


type 
    EmitterInfo* = object
        generator* : UPackagePtr->UFieldPtr
        ueType* : UEType
        uStructPointer* : UFieldPtr

    UEEmitter* = ref object 
        emitters* : seq[EmitterInfo]


var ueEmitter* = UEEmitter() 

proc addEmitterInfo*(ueType:UEType, fn : UPackagePtr->UFieldPtr) : void =  
    ueEmitter.emitters.add(EmitterInfo(ueType:ueType, generator:fn))

proc prepReinst(prev:UObjectPtr) = 
    prev.setFlags(RF_NewerVersionExists)

    # use explicit casting between uint32 and enum to avoid range checking bug https://github.com/nim-lang/Nim/issues/20024
    prev.clearFlags(cast[EObjectFlags](RF_Public.uint32 or RF_Standalone.uint32))

    let prevNameStr : FString =  fmt("{prev.getName()}_REINST")
    let oldClassName = makeUniqueObjectName(prev.getOuter(), prev.getClass(), makeFName(prevNameStr))
    discard prev.rename(oldClassName.toFString(), nil, REN_DontCreateRedirectors)

proc prepareForReinst(prevClass : UClassPtr) = 
    # prevClass.classFlags = prevClass.classFlags | CLASS_NewerVersionExists
    prevClass.addClassFlag CLASS_NewerVersionExists
    prepReinst(prevClass)

proc prepareForReinst(prevScriptStruct : UScriptStructPtr) = 
    prevScriptStruct.addScriptStructFlag(STRUCT_NewerVersionExists)
    prepReinst(prevScriptStruct)

proc prepareForReinst(prevDel : UDelegateFunctionPtr) = 
    prepReinst(prevDel)
proc prepareForReinst(prevUEnum : UNimEnumPtr) = discard 
    # prevUEnum.markNewVersionExists()
    # prepReinst(prevUEnum)


type UEmitable = UScriptStruct | UClass | UDelegateFunction | UEnum
        
#emit the type only if one doesn't exist already and if it's different
proc emitUStructInPackage[T : UEmitable ](pkg: UPackagePtr, emitter:EmitterInfo, prev:Option[ptr T]) : Option[ptr T]= 
    let areEquals = prev.isSome() and prev.get().toUEType() == emitter.ueType
    if areEquals: none[ptr T]()
    else: 
        prev.run prepareForReinst
        some ueCast[T](emitter.generator(pkg))

proc emitUStructsForPackage*(pkg: UPackagePtr) : FNimHotReloadPtr = 
    var hotReloadInfo = newNimHotReload()
    for emitter in ueEmitter.emitters:
        case emitter.ueType.kind:
        of uetStruct:
            let prevStructPtr = someNil getScriptStructByName emitter.ueType.name.removeFirstLetter()
            let newStructPtr = emitUStructInPackage(pkg, emitter, prevStructPtr)
            prevStructPtr.flatmap((prev : UScriptStructPtr) => newStructPtr.map(newStr=>(prev, newStr)))
                .run((pair:(UScriptStructPtr, UScriptStructPtr)) => hotReloadInfo.structsToReinstance.add(pair[0], pair[1]))
        of uetClass:
            let prevClassPtr = someNil getClassByName emitter.ueType.name.removeFirstLetter()
            let newClassPtr = emitUStructInPackage(pkg, emitter, prevClassPtr)
            prevClassPtr.flatmap((prev:UClassPtr) => newClassPtr.map(newCls=>(prev, newCls)))
                .run((pair:(UClassPtr, UClassPtr)) => hotReloadInfo.classesToReinstance.add(pair[0], pair[1]))
        of uetEnum:
            let prevEnumPtr = someNil getUTypeByName[UNimEnum](emitter.ueType.name)
            let newEnumPtr = emitUStructInPackage(pkg, emitter, prevEnumPtr)
            prevEnumPtr.flatmap((prev:UNimEnumPtr) => newEnumPtr.map(newEnum=>(prev, newEnum)))
                .run((pair:(UNimEnumPtr, UNimEnumPtr)) => hotReloadInfo.enumsToReinstance.add(pair[0], pair[1]))
        of uetDelegate:
            let prevDelPtr = someNil getUTypeByName[UDelegateFunction](emitter.ueType.name.removeFirstLetter())
            let newDelPtr = emitUStructInPackage(pkg, emitter, prevDelPtr)
            prevDelptr.flatmap((prev : UDelegateFunctionPtr) => newDelPtr.map(newDel=>(prev, newDel)))
                .run((pair:(UDelegateFunctionPtr, UDelegateFunctionPtr)) => hotReloadInfo.delegatesToReinstance.add(pair[0], pair[1]))
   
    hotReloadInfo.setShouldHotReload()
    hotReloadInfo


#By default ue types are emitted in the /Script/Nim package. But we can use another for the tests. 
proc emitUStructsForPackage*(pkgName:FString = "Nim") : FNimHotReloadPtr = 
    let pkg = findObject[UPackage](nil, convertToLongScriptPackageName("Nim"))
    emitUStructsForPackage(pkg)


proc emitUStruct(typeDef:UEType) : NimNode =
    let typeDecl = genTypeDecl(typeDef)
    
    let typeEmitter = genAst(name=ident typeDef.name, typeDefAsNode=newLit typeDef): #defers the execution
                addEmitterInfo(typeDefAsNode, (package:UPackagePtr) => emitUStruct[name](typeDefAsNode, package))

    result = nnkStmtList.newTree [typeDecl, typeEmitter]
    # debugEcho repr result

proc emitUClass(typeDef:UEType) : NimNode =
    let typeDecl = genTypeDecl(typeDef)
    
    let typeEmitter = genAst(name=ident typeDef.name, typeDefAsNode=newLit typeDef): #defers the execution
                addEmitterInfo(typeDefAsNode, (package:UPackagePtr) => emitUClass(typeDefAsNode, package))

    result = nnkStmtList.newTree [typeDecl, typeEmitter]

proc emitUDelegate(typedef:UEType) : NimNode = 
    let typeDecl = genTypeDecl(typedef)
    
    let typeEmitter = genAst(name=ident typedef.name, typeDefAsNode=newLit typedef): #defers the execution
                addEmitterInfo(typeDefAsNode, (package:UPackagePtr) => emitUDelegate(typeDefAsNode, package))

    result = nnkStmtList.newTree [typeDecl, typeEmitter]

proc emitUEnum(typedef:UEType) : NimNode = 
    let typeDecl = genTypeDecl(typedef)
    
    let typeEmitter = genAst(name=ident typedef.name, typeDefAsNode=newLit typedef): #defers the execution
                addEmitterInfo(typeDefAsNode, (package:UPackagePtr) => emitUEnum(typeDefAsNode, package))

    result = nnkStmtList.newTree [typeDecl, typeEmitter]
#iterate childrens and returns a sequence fo them
func childrenAsSeq*(node:NimNode) : seq[NimNode] =
    var nodes : seq[NimNode] = @[]
    for n in node:
        nodes.add n
    nodes
    
func fromStringAsMetaToFlag(meta:seq[string]) : (EPropertyFlags, seq[UEMetadata]) = 
    # var flags : EPropertyFlags = CPF_SkipSerialization
    var flags : EPropertyFlags = CPF_NoDestructor
    var metadata : seq[UEMetadata] = @[]
    #TODO THROW ERROR WHEN NON MULTICAST AND USE MC ONLY
    # var flags : EPropertyFlags = CPF_None
    #TODO a lot of flags are mutually exclusive, this is a naive way to go about it
    for m in meta:
        if m == "BlueprintReadOnly":
            flags = flags | CPF_BlueprintVisible | CPF_BlueprintReadOnly
        if m == "BlueprintReadWrite":
            flags = flags | CPF_BlueprintVisible
        if m == "EditAnywhere":
            flags = flags | CPF_Edit
        if m == "ExposeOnSpawn":
                flags = flags | CPF_ExposeOnSpawn
                metadata.add makeUEMetadata "ExposeOnSpawn"
        if m == "VisibleAnywhere":
                flags = flags | CPF_SimpleDisplay
        if m == "Transient":
                flags = flags | CPF_Transient
        if m == "BlueprintAssignable":
                flags = flags | CPF_BlueprintAssignable 
        if m == "BlueprintCallable":
                flags = flags | CPF_BlueprintCallable
            #Notice this is only required in the unlikely case that the user wants to use a delegate that is not exposed to Blueprint in any way
        #TODO CPF_BlueprintAuthorityOnly is only for MC
        

    (flags, metadata)
   


func fromUPropNodeToField(node : NimNode) : seq[UEField] = 
    let metas = node.childrenAsSeq()
                    .filter(n=>n.kind==nnkIdent and n.strVal().toLower() != "uprop")
                    .map(n=>n.strVal())
                    .fromStringAsMetaToFlag()

    func nodeToUEField (n: NimNode)  : UEField = #TODO see how to get the type implementation to discriminate between uProp and  uDelegate
        let typ = n[1].repr.strip()
        let name = n[0].repr
        
        if isMulticastDelegate typ:
            makeFieldAsUPropMulDel(name, typ, metas[0], metas[1])
        elif isDelegate typ:
            makeFieldAsUPropDel(name, typ, metas[0], metas[1])
        else:
            makeFieldAsUProp(name, typ, metas[0], metas[1])

    #TODO Metas to flags
    let ueFields = node.childrenAsSeq()
                   .filter(n=>n.kind==nnkStmtList)
                   .head()
                   .map(childrenAsSeq)
                   .get(@[])
                   .map(nodeToUEField)
    ueFields



func getMetasForType(body:NimNode) : seq[UEMetadata] {.compiletime.} = 
    body.toSeq()
        .filter(n=>n.kind==nnkPar or n.kind == nnkTupleConstr)
        .map(n => n.children.toSeq())
        .foldl( a & b, newSeq[NimNode]())
        .map(n=>n.strVal().strip())
        .map(makeUEMetadata)

func getUPropsAsFieldsForType(body:NimNode) : seq[UEField]  = 
    body.toSeq()
        .filter(n=>n.kind == nnkCall and n[0].strVal() == "uprop")
        .map(fromUPropNodeToField)
        .foldl(a & b)
        .reversed()
    
macro uStruct*(name:untyped, body : untyped) : untyped = 
    let structTypeName = name.strVal()#notice that it can also contains of meaning that it inherits from another struct
    let structMetas = getMetasForType(body)
    let ueFields = getUPropsAsFieldsForType(body)
    let structFlags = (STRUCT_NoFlags)
    let ueType = makeUEStruct(structTypeName, ueFields, "", structMetas, structFlags)

    emitUStruct(ueType) 

macro uClass*(name:untyped, body : untyped) : untyped = 
    if name.toSeq().len() < 3:
        error("uClass must explicitly specify the base class. (i.e UMyObject of UObject)", name)

    let parent = name[^1].strVal()
    let className = name[1].strVal()
    let classMetas = getMetasForType(body)
    let ueFields = getUPropsAsFieldsForType(body)
    let classFlags = (CLASS_Inherit | CLASS_ScriptInherit ) #| CLASS_CompiledFromBlueprint
    let ueType = makeUEClass(className, parent, classFlags, ueFields, classMetas)
    
    emitUClass(ueType)
  

macro uDelegate*(body:untyped) : untyped = 
    let name = body[0].strVal()
    let paramsAsFields = body.toSeq()
                             .filter(n=>n.kind==nnkExprColonExpr)
                             .map(n=>makeFieldAsUPropParam(n[0].strVal(), n[1].repr.strip()))
    let ueType = makeUEMulDelegate(name, paramsAsFields)
    emitUDelegate(ueType)


macro uEnum*(name:untyped, body : untyped) : untyped = 
    # echo body.treeRepr
    let name = name.strVal()
    let metas = getMetasForType(body)
    let fields = body.toSeq().filter(n=>n.kind==nnkIdent)
                    .map(n=>n.repr.strip())
                    .map(str=>makeFieldASUEnum(str))
    let ueType = makeUEEnum(name, fields, metas)
    emitUEnum(ueType)



