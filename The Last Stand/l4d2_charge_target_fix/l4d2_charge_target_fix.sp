#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>
#include <left4dhooks>

#define PLUGIN_VERSION "1.3"

public Plugin myinfo = 
{
	name = "[L4D2] Charger Target Fix",
	author = "Forgetest",
	description = "Fix multiple issues with charger targets.",
	version = PLUGIN_VERSION,
	url = "https://github.com/Target5150/MoYu_Server_Stupid_Plugins"
};

#define GAMEDATA_FILE "l4d2_charge_target_fix"
#define FUNCTION_NAME "CCharge::HandleCustomCollision"

#define KEY_ANIMSTATE "CTerrorPlayer::m_PlayerAnimState"
#define KEY_FLAG_CHARGED "CTerrorPlayerAnimState::m_bCharged"

int
	m_PlayerAnimState,
	m_bCharged;

enum AnimStateFlag // mid-way start from m_bCharged
{
	AnimState_WallSlammed		= 2,
	AnimState_GroundSlammed		= 3,
}

methodmap AnimState
{
	public AnimState(int client) {
		int ptr = GetEntData(client, m_PlayerAnimState, 4);
		if (ptr == 0)
			ThrowError("Invalid pointer to \"CTerrorPlayer::CTerrorPlayerAnimState\" (client %d).", client);
		return view_as<AnimState>(ptr);
	}
	public bool GetFlag(AnimStateFlag flag) {
		return view_as<bool>(LoadFromAddress(view_as<Address>(this) + view_as<Address>(m_bCharged) + view_as<Address>(flag), NumberType_Int8));
	}
}

static const float kChargerKnockdownDuration = 2.5;

int 
	g_iChargeVictim[MAXPLAYERS+1] = {-1, ...},
	g_iChargeAttacker[MAXPLAYERS+1] = {-1, ...};

bool g_bChargerCollision;
float g_flKnockdownWindow;

public void OnPluginStart()
{
	GameData gd = new GameData(GAMEDATA_FILE);
	if (!gd)
		SetFailState("Missing gamedata \""...GAMEDATA_FILE..."\"");
	
	m_PlayerAnimState = GameConfGetOffset(gd, KEY_ANIMSTATE);
	if (m_PlayerAnimState == -1)
		SetFailState("Missing offset \""...KEY_ANIMSTATE..."\"");
	
	m_bCharged = GameConfGetOffset(gd, KEY_FLAG_CHARGED);
	if (m_bCharged == -1)
		SetFailState("Missing offset \""...KEY_FLAG_CHARGED..."\"");
	
	DynamicDetour hDetour = DynamicDetour.FromConf(gd, FUNCTION_NAME);
	if (!hDetour)
		SetFailState("Missing detour setup \""...FUNCTION_NAME..."\"");
	if (!hDetour.Enable(Hook_Pre, DTR_CCharge__HandleCustomCollision))
		SetFailState("Failed to detour \""...FUNCTION_NAME..."\"");
	
	delete hDetour;
	delete gd;
	
	CreateConVarHook("z_charge_pinned_collision",
				"1",
				"Enable/Disable collision to Infected Team on Survivors pinned by charger.",
				FCVAR_SPONLY,
				true, 0.0, true, 1.0,
				CvarChg_ChargerCollision);
	
	CreateConVarHook("charger_knockdown_getup_window",
				"0.1",
				"Duration between knockdown timer ends and get-up finishes.\n"
			...	"The higher value is set, the earlier Survivors become collideable when getting up from charger.",
				FCVAR_SPONLY,
				true, 0.0, true, 4.0,
				CvarChg_KnockdownWindow);
	
	HookEvent("round_start", Event_RoundStart);
	HookEvent("charger_pummel_end", Event_ChargerPummelEnd);
	HookEvent("charger_killed", Event_ChargerKilled);
	HookEvent("player_bot_replace", Event_PlayerBotReplace);
	HookEvent("bot_player_replace", Event_BotPlayerReplace);
}

MRESReturn DTR_CCharge__HandleCustomCollision(int ability, DHookReturn hReturn, DHookParam hParams)
{
	if (!GetEntProp(ability, Prop_Send, "m_hasBeenUsed"))
		return MRES_Ignored;
	
	int attacker = GetEntPropEnt(ability, Prop_Send, "m_owner");
	if (attacker == -1)
		return MRES_Ignored;
	
	int victim = hParams.Get(1);
	if (!victim || victim > MaxClients)
		return MRES_Ignored;
	
	if (g_iChargeAttacker[victim] == -1)
		return MRES_Ignored;
	
	if (g_iChargeAttacker[victim] == attacker)
		return MRES_Ignored;
	
	hReturn.Value = 0;
	return MRES_Supercede;
}

void CvarChg_ChargerCollision(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bChargerCollision = convar.BoolValue;
}

void CvarChg_KnockdownWindow(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_flKnockdownWindow = convar.FloatValue;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i <= MaxClients; ++i)
	{
		if (IsClientInGame(i))
		{
			SetEntPropEnt(i, Prop_Send, "m_pummelVictim", -1);
			SetEntPropEnt(i, Prop_Send, "m_pummelAttacker", -1);
			
			L4D2_SetQueuedPummelStartTime(i, -1.0);
			L4D2_SetQueuedPummelVictim(i, -1);
			L4D2_SetQueuedPummelAttacker(i, -1);
		}
	}
}

void Event_ChargerPummelEnd(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client)
		return;
	
	int victimId = event.GetInt("victim");
	int victim = GetClientOfUserId(victimId);
	if (!victim || !IsClientInGame(victim))
		return;
	
	if (!g_bChargerCollision)
	{
		KnockdownPlayer(client, KNOCKDOWN_CHARGER);
		ExtendKnockdown(victim, false);
	}
	
	// Normal processes don't need special care
	g_iChargeVictim[client] = -1;
	g_iChargeAttacker[victim] = -1;
}

void Event_ChargerKilled(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || !IsClientInGame(client))
		return;
	
	int victim = g_iChargeVictim[client];
	if (victim == -1)
		return;
	
	if (!g_bChargerCollision)
	{
		KnockdownPlayer(client, KNOCKDOWN_CHARGER);
		RequestFrame(OnNextFrame_LongChargeKnockdown, GetClientUserId(victim));
	}
	
	g_iChargeVictim[client] = -1;
	g_iChargeAttacker[victim] = -1;
}

void OnNextFrame_LongChargeKnockdown(int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client))
		return;
	
	ExtendKnockdown(client, true);
}

void ExtendKnockdown(int client, bool isLongCharge)
{
	float flExtendTime = 0.0;
	
	if (!isLongCharge)
	{
		float flAnimTime = 85 / 30.0;
		flExtendTime = flAnimTime - kChargerKnockdownDuration - g_flKnockdownWindow;
	}
	else
	{
		AnimState pAnim = AnimState(client);
		
		float flAnimTime = 0.0;
		if (((flAnimTime = 116 / 30.0), !pAnim.GetFlag(AnimState_WallSlammed))
		  && ((flAnimTime = 119 / 30.0), !pAnim.GetFlag(AnimState_GroundSlammed)))
		{
			ExtendKnockdown(client, false);
			return;
		}
		
		float flElaspedAnimTime = flAnimTime * GetEntPropFloat(client, Prop_Send, "m_flCycle");
		flExtendTime = flAnimTime - flElaspedAnimTime - kChargerKnockdownDuration - g_flKnockdownWindow;
	}
	
	if (flExtendTime >= 0.1)
		CreateTimer(flExtendTime, Timer_ExtendKnockdown, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_ExtendKnockdown(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client))
		return Plugin_Stop;
	
	KnockdownPlayer(client, KNOCKDOWN_CHARGER);
	
	return Plugin_Stop;
}

void Event_PlayerBotReplace(Event event, const char[] name, bool dontBroadcast)
{
	HandlePlayerReplace(GetClientOfUserId(event.GetInt("bot")), GetClientOfUserId(event.GetInt("player")));
}

void Event_BotPlayerReplace(Event event, const char[] name, bool dontBroadcast)
{
	HandlePlayerReplace(GetClientOfUserId(event.GetInt("player")), GetClientOfUserId(event.GetInt("bot")));
}

void HandlePlayerReplace(int replacer, int replacee)
{
	if (!replacer || !IsClientInGame(replacer))
		return;
	
	if (GetClientTeam(replacer) == 3)
	{
		if (g_iChargeVictim[replacee] != -1)
		{
			g_iChargeVictim[replacer] = g_iChargeVictim[replacee];
			g_iChargeAttacker[g_iChargeVictim[replacee]] = replacer;
			g_iChargeVictim[replacee] = -1;
		}
	}
	else
	{
		if (g_iChargeAttacker[replacee] != -1)
		{
			g_iChargeAttacker[replacer] = g_iChargeAttacker[replacee];
			g_iChargeVictim[g_iChargeAttacker[replacee]] = replacer;
			g_iChargeAttacker[replacee] = -1;
		}
	}
}

public Action L4D_OnPouncedOnSurvivor(int victim, int attacker)
{
	if (g_iChargeAttacker[victim] == -1)
		return Plugin_Continue;
	
	return Plugin_Handled;
}

public Action L4D2_OnJockeyRide(int victim, int attacker)
{
	if (g_iChargeAttacker[victim] == -1)
		return Plugin_Continue;
	
	return Plugin_Handled;
}

public void L4D2_OnStartCarryingVictim_Post(int victim, int attacker)
{
	g_iChargeVictim[attacker] = victim;
	g_iChargeAttacker[victim] = attacker;
	TeleportEntity(victim, NULL_VECTOR, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
}

public void L4D2_OnSlammedSurvivor_Post(int victim, int attacker, bool bWallSlam, bool bDeadlyCharge)
{
	g_iChargeVictim[attacker] = victim;
	g_iChargeAttacker[victim] = attacker;
	TeleportEntity(victim, NULL_VECTOR, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
	
	if (!g_bChargerCollision)
	{
		Handle timer = CreateTimer(1.0, Timer_KnockdownRepeat, GetClientUserId(victim), TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
		TriggerTimer(timer);
	}
}

Action Timer_KnockdownRepeat(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client))
		return Plugin_Stop;
	
	if (GetClientTeam(client) != 2)
		return Plugin_Stop;
	
	if (!IsPlayerAlive(client))
		return Plugin_Stop;
	
	int queuedPummelAttacker = L4D2_GetQueuedPummelAttacker(client);
	if (queuedPummelAttacker == -1 || !L4D2_IsInQueuedPummel(queuedPummelAttacker))
	{
		if (GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") == -1)
			return Plugin_Stop;
	}
	
	KnockdownPlayer(client, KNOCKDOWN_CHARGER);
	
	return Plugin_Continue;
}

void KnockdownPlayer(int client, int reason)
{
	SetEntProp(client, Prop_Send, "m_knockdownReason", reason);
	SetEntPropFloat(client, Prop_Send, "m_knockdownTimer", GetGameTime(), 0);
}

ConVar CreateConVarHook(const char[] name,
	const char[] defaultValue,
	const char[] description="",
	int flags=0,
	bool hasMin=false, float min=0.0,
	bool hasMax=false, float max=0.0,
	ConVarChanged callback)
{
	ConVar cv = CreateConVar(name, defaultValue, description, flags, hasMin, min, hasMax, max);
	
	Call_StartFunction(INVALID_HANDLE, callback);
	Call_PushCell(cv);
	Call_PushNullString();
	Call_PushNullString();
	Call_Finish();
	
	cv.AddChangeHook(callback);
	
	return cv;
}
