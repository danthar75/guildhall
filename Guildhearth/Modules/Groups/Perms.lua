local ADDON, ns = ...

-- Group finder permission keys. Registered early (before Core/Boot.lua) so the Permissions grid
-- and the change history know them. Until the guild master changes them, only the guild master
-- holds them. raidlead = true: a grant may also cover the raid leader and assistants.
ns.Permissions.AddKey({ key = "checklists", label = "Edit raid checklists", raidlead = true })
ns.Permissions.AddKey({ key = "prepared", label = "Confirm prepared", raidlead = true })
ns.Permissions.AddKey({ key = "flex", label = "Ask for spec switches", raidlead = true })
