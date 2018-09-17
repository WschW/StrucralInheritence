module StructuralInheritance

export @protostruct, @superconstructor

#Stores prototype field definitions
const fieldBacking = Dict{Union{Type,Missing},Vector{Any}}()

#prototype -> self
#concrete -> prototype
const shadowMap = Dict{Type,Type}()


"""
Creates an abstract type with the given name
"""
function abstracttype(name)
  basicForm = :(abstract type Replace end)
  basicForm.args[1] = name
  basicForm
end


"""
returns an array with only the field definitions
"""
function filtertofields(_quote)
  filter(x->typeof(x)==Symbol || (typeof(x) == Expr && x.head == :(::)),_quote.args)
end

"""
gets the name of a struct definition
"""
function extractname(leaf)
  leaf.args[2]
end

"""
extracts the fields from a struct definition
"""
function extractfields(leaf)
  filtertofields(leaf.args[3])
end


function newnames(structDefinition,module_)
  """
  handle inheritence conversions
  """
  function rectify(x)
    val = module_.eval(x)
    if !(typeof(val) <: Type)
      throw("must inherit from a type")
    end
    if isabstracttype(val)
      x
    elseif haskey(shadowMap,val)
      :($(shadowMap[val]))
    else
      throw("inheritence from concrete types is limited to those defined by @protostruct, $val not found")
    end
  end

  nameNode = structDefinition.args[2]

  if typeof(nameNode) <: Symbol
    protoName = Symbol("Proto",nameNode)
    return (:($nameNode <: $protoName),protoName,nameNode,protoName)
  end

  if nameNode.head == :curly
    protoName = deepcopy(nameNode)
    protoName.args[1] = Symbol("Proto",nameNode.args[1])
    return (:( $(nameNode) <: $(protoName)),
            protoName,
            nameNode,
            protoName)
  end

  if nameNode.head == :<:
    inheritFrom = rectify(deepcopy(nameNode.args[2]))
    structHead = deepcopy(nameNode.args[1])

    if typeof(nameNode.args[1]) <: Expr && nameNode.args[1].head == :curly
        protoName = deepcopy(nameNode)
        protoName.args[1].args[1] = Symbol("Proto",nameNode.args[1].args[1])
        protoName.args[2] = inheritFrom
        return (:( $(nameNode.args[1]) <: $(protoName.args[1])),
                protoName,
                nameNode.args[1],
                protoName.args[1])

    elseif typeof(nameNode.args[1]) <: Symbol
      protoName = deepcopy(nameNode)
      protoName.args[1] = Symbol("Proto",nameNode.args[1])
      protoName.args[2] = inheritFrom
      return (:( $(nameNode.args[1]) <: $(protoName.args[1])),
              protoName,
              nameNode.args[1],
              protoName.args[1])
    end
  end

  throw("structure of strucure name not identified")
end


function fieldsymbols(fields)
    function symbol(x)
        if typeof(x) <: Symbol
            x
        else
            x.args[1]::Symbol
        end
    end
    symbol.(fields)
end

"""
throws an error is the fields contain overlapping symbols
"""
function assertcollisionfree(x,y)
    if !isempty(intersect(Set(fieldsymbols(x)),Set(fieldsymbols(y))))
        throw("Field defined in multiple locations")
    end
end

"""
returns a copy with replacement fields
"""
function replacefields(struct_,fields)
    out = deepcopy(struct_)
    out.args[3].args = fields
    out
end

"""
annotates module information to unanotated typed fields
"""
function sanitize(module_,fields)
  fields = deepcopy(fields)
  modulePath = fullname(module_)
  function addpath(x)
    annotationPath = push!(Any[modulePath...],x)
    while length(annotationPath) > 1
      first = pop!(annotationPath)
      second = pop!(annotationPath)
      push!(annotationPath,:($(second).$(first)))
    end
    annotationPath[1]
  end

  function addpathif(x)
    if typeof(x) <: Symbol
      x
    else
      x.args[2] = addpath(x.args[2])
      x
    end
  end

  addpathif.(fields)
end


"""
returns a renamed struct
"""
function rename(struct_,name)
    newStruct = deepcopy(struct_)
    newStruct.args[2] = name
    newStruct
end

"""
strips parameterization off of a name that does
not include inheritence information
"""
function deparametrize_lightName(name)
    if typeof(name) <: Expr && name.head == :curly
        name.args[1]
    else
        name
    end
end

function register(module_,newStructName,prototypeName,fields)
    nSName =  deparametrize_lightName(newStructName)
    pName = deparametrize_lightName(prototypeName)

    concrete = module_.eval(nSName)
    proto = module_.eval(pName)
    StructuralInheritance.fieldBacking[proto] = fields
    StructuralInheritance.shadowMap[concrete] = proto
    StructuralInheritance.shadowMap[proto] = proto
end


macro protostruct(struct_)
  #dump(struct_)
  newName,name,newStructLightName,lightname = newnames(struct_,__module__)
  fields = extractfields(struct_)
  D1_struct = gensym()
  D1_fields = gensym()
  sanitizedFields = sanitize(__module__,fields)
  prototypeDefinition = abstracttype(name)
  structDefinition = rename(struct_,newName)
  if typeof(name) <: Symbol || name.head == :curly
    esc(quote
      $prototypeDefinition
      $structDefinition
      StructuralInheritance.register($__module__,
                                     $(Meta.quot(newStructLightName)),
                                     $(Meta.quot(lightname)),
                                     $(Meta.quot(sanitizedFields)))
  end)

  else #inheritence case
    D1_oldFields = gensym()
    D1_struct = gensym()
    D1_parentType = gensym()
    esc(quote
      $D1_parentType = get(StructuralInheritance.shadowMap,$(name.args[2]),missing)
      $D1_oldFields = get(StructuralInheritance.fieldBacking,$D1_parentType ,[])
      $D1_fields = $(Meta.quot(fields))
      StructuralInheritance.assertcollisionfree($D1_fields,$D1_oldFields)
      $prototypeDefinition
      $D1_fields = StructuralInheritance.sanitize($__module__,$D1_fields)
      $D1_fields = vcat($D1_fields,$D1_oldFields)

      $D1_struct = StructuralInheritance.rename($(Meta.quot(structDefinition)),$(Meta.quot(newName)))
      $D1_struct = StructuralInheritance.replacefields($D1_struct,$D1_fields)

      #dump($D1_struct); print($D1_struct)
      eval($D1_struct)

      StructuralInheritance.register($__module__,
                                     $(Meta.quot(newStructLightName)),
                                     $(Meta.quot(lightname)),
                                     $(Meta.quot(sanitizedFields)))

    end)
  end

end


#TODO: Rewrite for more efficient code.
"""
Calls the provided constructor of the supertype the strucure is inherited from.
and sets local fields based on that.
"""
macro superconstructor(constructor,self::Symbol = gensym())
  val = gensym()
  fields = gensym()
  field = gensym()
  esc(quote
    $val = constructor
    $fields = fieldnames(typeof($val))
    $self = new()
    for $field = $fields
        setfield!($self,$field,getfield($val,$field))
    end
  end)
end

end
