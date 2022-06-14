
type 
    TPair*[K, V] {.importcpp:"TPair<'0, '1>", bycopy .} = object
        key: K
        value: V

    TMap*[K, V] {.importcpp: "TMap<'0, '1>", bycopy } = object


proc makeTPair*[K, V](k:K, v:V) : TPair[K, V] {.importcpp: "TPair<'1, '2>(@)", constructor .}

proc makeTMap*[K, V]() : TMap[K, V] {.importcpp: "TMap<'1, '2>()", constructor .}

proc add*[K, V](map : TMap[K, V], pair:TPair[K, V]) : void  {.importcpp: "#.Add(@)", .}
proc add*[K, V](map : TMap[K, V], k:K, v:V) : void  {.importcpp: "#.Add(@)", .}

proc num*[K, V](arr:TMap[K, V]): int32 {.importcpp: "#.Num()" noSideEffect}

proc contains*[K, V](arr:TMap[K, V], key:K): bool {.importcpp: "#.Contains(#)" noSideEffect}


proc `[]`*[K, V](map:TMap[K, V], key: K): var V {. importcpp: "#[#]",  noSideEffect.}
proc `[]=`*[K, V](map:TMap[K, V], key: K, val : V)  {. importcpp: "#[#]=#",  }

#TODO Keys(), Values() and Iterators (no need to bind the Cpp ones)