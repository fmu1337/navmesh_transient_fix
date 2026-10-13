/**
 * NavMesh Transient Fix (CS:S v34)
 *
 * CNavMesh keeps a CUtlVector<CNavArea*> m_transientAreas of areas flagged NAV_MESH_TRANSIENT (0x100).
 * In the v34 server binary CNavMesh::DestroyNavigationMesh() does not clear that vector (Source SDK 2013 does:
 * m_transientAreas.RemoveAll()), so after a map change it still points to the freed CNavArea objects of the
 * previous map. CCSBotManager::StartFrame() periodically walks the list and calls CNavArea::UpdateBlocked() on
 * every entry, which writes m_isBlocked into freed heap memory -> heap corruption -> random crashes/hangs later.
 *
 * Fix: on map end set the vector's element count to 0 (exactly what CUtlVector::RemoveAll() does for pointers;
 * the buffer is kept and reused). The next map's nav load rebuilds the list through CNavMesh::AddNavArea(),
 * so transient areas (dynamic route blocking, e.g. cs_havana) keep working.
 *
 * Written in SM 1.4 syntax: one build (spcomp 1.4.2) runs on SourceMod 1.4 ... 1.13.
 */
#include <sourcemod>

#pragma semicolon 1

#define PLUGIN_VERSION "0.0.0-dev"

public Plugin:myinfo =
{
	name = "NavMesh Transient Fix",
	author = "Danyas",
	description = "Clears CNavMesh transient area list on map end (fixes v34 use-after-free crash)",
	version = PLUGIN_VERSION,
	url = "https://github.com/fmu1337/navmesh_transient_fix_v34"
};

new Address:g_pTheNavMeshVar = Address_Null;   // address of the global 'CNavMesh *TheNavMesh'
new g_iOffsetVector = -1;                        // CNavMesh: m_transientAreas.m_Memory.m_pMemory
new g_iOffsetAlloc = -1;                         // CNavMesh: m_transientAreas.m_Memory.m_nAllocationCount
new g_iOffsetSize = -1;                          // CNavMesh: m_transientAreas.m_Size

public OnPluginStart()
{
	// the offsets belong to the pre-OrangeBox (EP1) v34 binary; on newer engines Valve already fixed the bug
	if (GuessSDKVersion() != SOURCE_SDK_EPISODE1)
	{
		SetFailState("Only for CS:S v34 (Episode 1 engine); newer engines clear the list themselves");
	}

	new Handle:gd = LoadGameConfigFile("navmesh_transient_fix.games");
	if (gd == INVALID_HANDLE)
	{
		SetFailState("Missing gamedata navmesh_transient_fix.games.txt");
	}

	g_pTheNavMeshVar = GameConfGetAddress(gd, "TheNavMesh");
	g_iOffsetVector = GameConfGetOffset(gd, "CNavMesh::m_transientAreas");
	g_iOffsetAlloc = GameConfGetOffset(gd, "CNavMesh::m_transientAreas_Alloc");
	g_iOffsetSize = GameConfGetOffset(gd, "CNavMesh::m_transientAreas_Size");
	CloseHandle(gd);

	if (g_pTheNavMeshVar == Address_Null || g_iOffsetVector < 0 || g_iOffsetAlloc < 0 || g_iOffsetSize < 0)
	{
		SetFailState("Gamedata lookup failed (TheNavMesh=%x vec=%d alloc=%d size=%d)", g_pTheNavMeshVar, g_iOffsetVector, g_iOffsetAlloc, g_iOffsetSize);
	}

	CreateConVar("sm_navfix_version", PLUGIN_VERSION, "NavMesh Transient Fix version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	RegServerCmd("sm_navfix_status", Cmd_Status, "Show CNavMesh transient area list state");
}

Address:GetNavMesh()
{
	return Address:LoadFromAddress(g_pTheNavMeshVar, NumberType_Int32);
}

ReadField(Address:nav, offset)
{
	return LoadFromAddress(Address:(_:nav + offset), NumberType_Int32);
}

// refuse to write if the fields do not look like a CUtlVector (wrong binary / wrong offsets)
bool:LooksLikeVector(mem, alloc, size)
{
	if (size < 0 || alloc < 0 || size > alloc || alloc > 65536)
	{
		return false;
	}
	return size == 0 || mem != 0;
}

public OnMapEnd()
{
	new Address:nav = GetNavMesh();
	if (nav == Address_Null)
	{
		return;
	}

	new mem = ReadField(nav, g_iOffsetVector);
	new alloc = ReadField(nav, g_iOffsetAlloc);
	new size = ReadField(nav, g_iOffsetSize);

	if (!LooksLikeVector(mem, alloc, size))
	{
		LogError("Transient list looks invalid (mem=0x%x alloc=%d size=%d) - wrong server binary? Not touching it.", mem, alloc, size);
		return;
	}

	if (size > 0)
	{
		StoreToAddress(Address:(_:nav + g_iOffsetSize), 0, NumberType_Int32);
		LogMessage("Cleared %d transient nav area(s) on map end", size);
	}
}

public Action:Cmd_Status(args)
{
	new Address:nav = GetNavMesh();
	if (nav == Address_Null)
	{
		PrintToServer("[navfix] TheNavMesh is NULL");
		return Plugin_Handled;
	}
	new mem = ReadField(nav, g_iOffsetVector);
	new alloc = ReadField(nav, g_iOffsetAlloc);
	new size = ReadField(nav, g_iOffsetSize);
	PrintToServer("[navfix] TheNavMesh=0x%x transient list mem=0x%x alloc=%d size=%d %s",
		nav, mem, alloc, size, LooksLikeVector(mem, alloc, size) ? "(ok)" : "(INVALID)");
	return Plugin_Handled;
}
