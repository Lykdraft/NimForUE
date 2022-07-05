include ../unreal/prelude
import std/[times,strformat, strutils, options, sugar, sequtils]
import models
export models

func isTArray(prop:FPropertyPtr) : bool = not castField[FArrayProperty](prop).isNil()
func isTMap(prop:FPropertyPtr) : bool = not castField[FMapProperty](prop).isNil()
func isTEnum(prop:FPropertyPtr) : bool = "TEnumAsByte" in prop.getName()
func isDynDel(prop:FPropertyPtr) : bool = not castField[FDelegateProperty](prop).isNil()
func isMulticastDel(prop:FPropertyPtr) : bool = not castField[FMulticastDelegateProperty](prop).isNil()
#TODO Dels

func getNimTypeAsStr(prop:FPropertyPtr) : string = #The expected type is something that UEField can understand
    if prop.isTArray(): 
        let innerType = castField[FArrayProperty](prop).getInnerProp().getCPPType()
        return fmt"TArray[{innerType}]"

    if prop.isTMap(): #better pattern here, i.e. option chain
        let mapProp = castField[FMapProperty](prop)
        let keyType = mapProp.getKeyProp().getCPPType()
        let valueType = mapProp.getValueProp().getCPPType()
        return fmt"TMap[{keyType}, {valueType}]"

    let cppType = prop.getCPPType() 

    if prop.isTEnum(): #Not sure if it would be better to just support it on the macro
        return cppType.replace("TEnumAsByte<","")
                      .replace(">", "")


    let nimType = cppType.replace("<", "[")
                         .replace(">", "]")
                         .replace("*", "Ptr")
    
    return nimType


#Function that receives a FProperty and returns a Type as string
func toUEField*(prop:FPropertyPtr) : UEField = #The expected type is something that UEField can understand
    let name = prop.getName()
    let nimType = prop.getNimTypeAsStr()
     

    if prop.isDynDel() or prop.isMulticastDel():
        let signature = if prop.isDynDel(): 
                            castField[FDelegateProperty](prop).getSignatureFunction() 
                        else: 
                            castField[FMulticastDelegateProperty](prop).getSignatureFunction()
        
        var signatureAsStrs = getFPropsFromUStruct(signature)
                                .map(prop=>getNimTypeAsStr(prop))
        return makeFieldAsDel(name, uedelDynScriptDelegate, signatureAsStrs)


    return makeFieldAsUProp(prop.getName(), nimType, prop.getPropertyFlags())


func toUEField*(ufun:UFunctionPtr) : UEField = 
    let params = getFPropsFromUStruct(ufun).map(toUEField)
    # UE_Warn(fmt"{ufun.getName()}")
    makeFieldAsUFun(ufun.getName(), params, ufun.functionFlags)
    

func toUEType*(cls:UClassPtr) : UEType =
    let fields = getFuncsFromClass(cls)
                    .map(toUEField) & 
                 getFPropsFromUStruct(cls)
                    .map(toUEField)

    let name = cls.getPrefixCpp() & cls.getName()
    let parent = cls.getSuperClass()
    let parentName = parent.getPrefixCpp() & parent.getName()
    UEType(name:name, kind:uClass, parent:parentName, fields:fields)




proc toFProperty*(propField:UEField, outer : UStructPtr) : FPropertyPtr = 
    let flags = RF_NoFlags #OBJECT FLAGS
    let name = propField.name.makeFName()
    let prop : FPropertyPtr =   
                if propField.uePropType == "FString": 
                    makeFStrProperty(makeFieldVariant(outer), name, flags)
                elif propField.uePropType == "int32":
                    makeFIntProperty(makeFieldVariant(outer), name, flags)
                else:
                    raise newException(Exception, "FProperty not covered in the types for " & propField.uePropType)
    
    prop.setPropertyFlags(propField.propFlags)
    outer.addCppProperty(prop)
    prop

proc createProperty*(propField:UEField, outer : UStructPtr) : FPropertyPtr = propField.toFProperty(outer)

proc toUClass*(ueType : UEType, package:UPackagePtr) : UClassPtr =
    let 
        objClsFlags  =  (RF_Public | RF_Standalone | RF_Transactional | RF_LoadCompleted)
        newCls = newUObject[UClass](package, makeFName(ueType.name.removeFirstLetter()), objClsFlags)
        parent = getClassByName(ueType.parent.removeFirstLetter())
    
    assetCreated(newCls)

    newCls.classConstructor = nil
    newCls.propertyLink = parent.propertyLink
    newCls.classWithin = parent.classWithin
    newCls.classConfigName = parent.classConfigName
    newcls.setSuperStruct(parent)
    newcls.classFlags =  ueType.clsFlags & parent.classFlags
    newCls.classCastFlags = parent.classCastFlags
    
    copyMetadata(parent, newCls)
    newCls.setMetadata("IsBlueprintBase", "true") #todo move to ueType
    
    for field in ueType.fields:
        let fProp = field.toFProperty(newCls) #refactor this and move it to this file


    newCls.bindCls()
    newCls.staticLink(true)
    # broadcastAsset(newCls) Dont think this is needed since the notification will be done in the boundary of the plugin
    newCls



#note at some point class can be resolved from the UEField?
proc toUFunction*(fnField : UEField, cls:UClassPtr, fnImpl:UFunctionNativeSignature) : UFunctionPtr = 
    let fnName = fnField.name.makeFName()
    var fn = newUObject[UFunction](cls, fnName)
    fn.functionFlags = fnField.fnFlags

    fn.Next = cls.Children 
    cls.Children = fn

    
    for field in fnField.signature:
        let fprop =  field.toFProperty(fn)
        # UE_Warn "Has Return " & $ (CPF_ReturnParm in fprop.getPropertyFlags())

    cls.addFunctionToFunctionMap(fn, fnName)

    fn.setNativeFunc(makeFNativeFuncPtr(fnImpl))
    
    fn.staticLink(true)
    # fn.parmsSize = uprops.foldl(a + b.getSize(), 0) doesnt seem this is necessary 
   
    fn

proc createUFunctionInClass*(cls:UClassPtr, fnField : UEField, fnImpl:UFunctionNativeSignature) : UFunctionPtr = 
    fnField.toUFunction(cls, fnImpl)