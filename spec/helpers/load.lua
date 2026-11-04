-- Busted helper: loads addon files the way WoW does (varargs: addon name, namespace).
function loadAddonFile(ns, relPath)
  local f, err = loadfile(relPath)
  if not f then error(err, 2) end
  return f("Guildhearth", ns)
end
