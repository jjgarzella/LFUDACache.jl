module LFUDACache

export LFUDA

using DataStructures

include("cache_item.jl")
mutable struct LFUDA{K,V} <: AbstractDict{K,V}
  cache::Dict{K, Tuple{Integer, CacheItem{V}}} # Integer is a node index in heap
  heap::MutableBinaryMinHeap{CacheHeapNode{K,V}}
  age::Float64
  priority_key_policy::Function
  current_size::Int
  maxsize::Integer
  lock::ReentrantLock
  finalizer::Any

  function LFUDA{K,V}(; maxsize::Integer, priority_key_policy::Function=lfuda_priority_key_policy, finalizer=nothing) where {K,V}
    new(
      Dict{K,Tuple{Integer, CacheItem{V}}}(),
      MutableBinaryMinHeap{CacheHeapNode{K,V}}(),
      0,
      priority_key_policy,
      0,
      maxsize,
      ReentrantLock(),
      finalizer
    )
  end
end

Base.show(io::IO, lfuda::LFUDA{K,V}) where {K,V} =
  print(io, "LFUDA{$K, $V}(; maxsize = $(lfuda.maxsize))")

Base.iterate(lfuda::LFUDA, state...) = iterate(lfuda.cache, state...)
Base.length(lfuda::LFUDA) = length(lfuda.cache)
Base.isempty(lfuda::LFUDA) = isempty(lfuda.cache)
function Base.sizehint!(lfuda::LFUDA, n::Integer)
  lock(lfuda.lock) do
    sizehint!(lfuda.cache, n)
  end
  return lfuda
end

_unsafe_haskey(lfuda::LFUDA, key) = haskey(lfuda.cache, key)
function Base.haskey(lfuda::LFUDA, key)
  lock(lfuda.lock) do
    return _unsafe_haskey(lfuda, key)
  end
end

function _unsafe_retrieve_cache(lfuda::LFUDA{K,V}, key::K)::Union{Nothing, V} where {K,V}
  cache_tuple = get(lfuda.cache, key, nothing)

  isnothing(cache_tuple) && return nothing

  node_index, cache_item = cache_tuple

  hit_cache_item!(lfuda, node_index, key, cache_item)

  cache_item.data
end

function Base.getindex(lfuda::LFUDA, key)
  lock(lfuda.lock) do
    cache_value = _unsafe_retrieve_cache(lfuda, key)

    isnothing(cache_value) && throw(KeyError(key))

    return cache_value
  end
end

function Base.get(lfuda::LFUDA, key, default)
  lock(lfuda.lock) do
    cache_value = _unsafe_retrieve_cache(lfuda, key)

    isnothing(cache_value) && return default

    cache_value
  end
end

function Base.get(default::Base.Callable, lfuda::LFUDA, key)
  lock(lfuda.lock) do
    cache_value = _unsafe_retrieve_cache(lfuda, key)

    isnothing(cache_value) && return default()

    cache_value
  end
end

function Base.get!(lfuda::LFUDA{K, V}, key::K, default::V; size::Integer=1)::V where {K,V}
  v =
    lock(lfuda.lock) do
      cache_value = _unsafe_retrieve_cache(lfuda, key)

      !isnothing(cache_value) && return cache_value

      cache_item = insert_cache_item!(lfuda, key, default, size)

      cache_item.data
    end
end

function Base.get!(default::Base.Callable, lfuda::LFUDA{K, V}, key::K; size::Integer=1)::V where {K,V}
  v =
    lock(lfuda.lock) do
      cache_value = _unsafe_retrieve_cache(lfuda, key)

      !isnothing(cache_value) && return cache_value

      cache_item = insert_cache_item!(lfuda, key, default(), size)

      cache_item.data
    end
end

function Base.setindex!(lfuda::LFUDA{K, V}, value::V, key::K; size::Int=1)::V where {K,V}
  lock(lfuda.lock) do
    cache_tuple = get(lfuda.cache, key, nothing)

    cache_item =
      if isnothing(cache_tuple)
        insert_cache_item!(lfuda, key, value, size)
      else
        node_index, = cache_tuple

        replace_cache_item!(lfuda, node_index, key, value, size)
      end

    return cache_item.data
  end
end

function Base.delete!(lfuda::LFUDA{K,V}, key::K)::LFUDA{K,V} where {K,V}
  lock(lfuda.lock) do
    cache_tuple = get(lfuda.cache, key, nothing)

    isnothing(cache_tuple) && return lfuda

    node_index, cache_item = cache_tuple

    delete!(lfuda.heap, node_index)
    delete!(lfuda.cache, key)
    lfuda.current_size -= 1

    # finalize if necessary
    if lfuda.finalizer != nothing
        lfuda.finalizer(key, cache_item.data)
    end

    return lfuda
  end
end

function replace_cache_item!(lfuda::LFUDA{K, V}, node_index::Integer, key::K, value::V, size::Integer)::CacheItem{V} where {K,V}
  cache_item = CacheItem{V}(value, size)

  hit_cache_item!(lfuda, node_index, key, cache_item)

  # finalize if necessary
  #old_cache_tuple = get(lfuda.cache,key,nothing)
  #if !isnothing(old_cache_tuple)
  #    _, old_cache_item = old_cache_tuple
  #    finalizer(key,old_cache_item)
  #end

  lfuda.cache[key] = (node_index, cache_item)


  cache_item
end

function hit_cache_item!(lfuda::LFUDA{K,V}, node_index::Integer, key::K, cache_item::CacheItem{V}) where {K,V}
  cache_item.frequency += 1
  cache_item.priority_key = lfuda.priority_key_policy(cache_item, lfuda.age)

  cache_heap_node = CacheHeapNode(key, cache_item)

  update!(lfuda.heap, node_index, cache_heap_node)
end

function insert_cache_item!(lfuda::LFUDA{K, V}, key::K, value::V, size::Integer)::CacheItem{V} where {K, V}
  should_evict(lfuda) && evict!(lfuda)

  cache_item = CacheItem{V}(value, size)

  cache_item.frequency = 1
  cache_item.priority_key = lfuda.priority_key_policy(cache_item, lfuda.age)

  lfuda.maxsize == 0 && return cache_item;

  node_index = push!(lfuda.heap, CacheHeapNode(key, cache_item))
  lfuda.cache[key] = (node_index, cache_item)
  lfuda.current_size += 1

  cache_item
end

function evict!(lfuda::LFUDA)
  cache_heap_node = pop!(lfuda.heap)
  
  lfuda.age = cache_heap_node.cache_item.priority_key
  lfuda.current_size -= 1

  cache_tuple = get(lfuda.cache, cache_heap_node.key, nothing)

  # finalize if necessary
  if !isnothing(cache_tuple) && !isnothing(lfuda.finalizer)
      node_index, cache_item = cache_tuple
      lfuda.finalizer(cache_heap_node.key, cache_item.data)
  end

  delete!(lfuda.cache, cache_heap_node.key)
end

function should_evict(lfuda::LFUDA)::Bool
  lfuda.current_size == lfuda.maxsize && lfuda.current_size > 0
end

end
