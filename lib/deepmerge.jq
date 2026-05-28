# deepmerge(a; b): recursively merge object b into object a.
# Arguments are bound immediately to avoid re-evaluation inside reduce.
# Objects: merge keys (b wins on scalar conflict).
# Arrays: concatenate (b elements appended to a).
# Scalars: b replaces a.
def deepmerge(a; b):
  a as $a | b as $b |
  if   ($a | type) == "object" and ($b | type) == "object" then
    reduce ($b | keys_unsorted[]) as $k ($a;
      if ($a[$k] | type) == "object" and ($b[$k] | type) == "object"
      then .[$k] = deepmerge($a[$k]; $b[$k])
      elif ($a[$k] | type) == "array" and ($b[$k] | type) == "array"
      then .[$k] += $b[$k]
      else .[$k] = $b[$k]
      end)
  else $b
  end;

# diff(b; l): return the keys/values present in live (l) that are absent
# from or different to base (b). Produces a snippet that, when deepmerged
# into b, reproduces l.
def diff(b; l):
  b as $b | l as $l |
  if   ($b | type) == "object" and ($l | type) == "object" then
    reduce ($l | keys_unsorted[]) as $k ({};
      if   ($b | has($k) | not) then .[$k] = $l[$k]
      elif $b[$k] == $l[$k]     then .
      else
        diff($b[$k]; $l[$k]) as $sub
        | if $sub == {} or $sub == [] then . else .[$k] = $sub end
      end)
  elif ($b | type) == "array" and ($l | type) == "array" then
    [ $l[] | select(. as $x | ($b | index($x)) | not) ]
  else $l
  end;
