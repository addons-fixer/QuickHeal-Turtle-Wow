function QuickHeal_Priest_GetRatioHealthyExplanation()
    if QuickHealVariables.RatioHealthyPriest >= QuickHealVariables.RatioFull then
        return QUICKHEAL_SPELL_FLASH_HEAL .. " will always be used in combat, and "  .. QUICKHEAL_SPELL_LESSER_HEAL .. ", " .. QUICKHEAL_SPELL_HEAL .. " or " .. QUICKHEAL_SPELL_GREATER_HEAL .. " will be used when out of combat. ";
    else
        if QuickHealVariables.RatioHealthyPriest > 0 then
            return QUICKHEAL_SPELL_FLASH_HEAL .. " will be used in combat if the target has less than " .. QuickHealVariables.RatioHealthyPriest*100 .. "% life, and " .. QUICKHEAL_SPELL_LESSER_HEAL .. ", " .. QUICKHEAL_SPELL_HEAL .. " or " .. QUICKHEAL_SPELL_GREATER_HEAL .. " will be used otherwise. ";
        else
            return QUICKHEAL_SPELL_FLASH_HEAL .. " will never be used. " .. QUICKHEAL_SPELL_LESSER_HEAL .. ", " .. QUICKHEAL_SPELL_HEAL .. " or " .. QUICKHEAL_SPELL_GREATER_HEAL .. " will always be used in and out of combat. ";
        end
    end
end

function QuickHeal_Priest_FindHealSpellToUse(Target, healType, multiplier, forceMaxHPS)
    local SpellID = nil;
    local HealSize = 0;
    local Overheal = false;
    local ForceGH = false;

    -- Return immediately if no player needs healing
    if not Target then
        return SpellID,HealSize;
    end

    if multiplier ~= nil and multiplier > 1.0 then
        Overheal = true;
    end

    -- +Healing-PenaltyFactor = (1-((20-LevelLearnt)*0.0375)) for all spells learnt before level 20
    local PF1 = 0.2875;
    local PF4 = 0.4;
    local PF10 = 0.625;
    local PF18 = 0.925;

    -- Determine health and healneed of target
    local healneed;
    local Health;

    if QuickHeal_UnitHasHealthInfo(Target) then
    -- Full info available
        local incHeal = HealComm:getHeal(UnitName(Target));
        healneed = UnitHealthMax(Target) - UnitHealth(Target) - incHeal;
        if healneed < 0 then healneed = 0; end
        if Overheal then
            healneed = healneed * multiplier;
        end
        -- Use predicted health (after incoming heals) for TargetIsHealthy determination
        Health = (UnitHealth(Target) + incHeal) / UnitHealthMax(Target);
    else
        -- Estimate target health (no reliable HealComm data for external targets)
        healneed = QuickHeal_EstimateUnitHealNeed(Target,true);
        if Overheal then
            healneed = healneed * multiplier;
        end
        Health = UnitHealth(Target)/100;
    end

    QuickHeal_debug(">>> healneed is " .. healneed .. " <<<")

    local Bonus = 0
    if (AceLibrary and AceLibrary:HasInstance("ItemBonusLib-1.0")) then
        local itemBonus = AceLibrary("ItemBonusLib-1.0")
        Bonus = itemBonus:GetBonus("HEAL") or 0
        QuickHeal_debug(string.format("Equipment Healing Bonus: %d", Bonus))
    end

    -- Spiritual Guidance - Increases spell damage and healing by up to 5% (per rank) of your total Spirit.
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,12);
    local _,Spirit,_,_ = UnitStat('player',5);
    local sgMod = Spirit * 5*talentRank/100;
    QuickHeal_debug(string.format("Spiritual Guidance Bonus: %f", sgMod));

    -- Calculate healing bonus
    local healMod15 = (1.5/3.5) * (sgMod + Bonus) * 0.85;
    local healMod20 = (2.0/3.5) * (sgMod + Bonus) * 0.85;
    local healMod25 = (2.5/3.5) * (sgMod + Bonus) * 0.85;
    local healMod30 = (3.0/3.5) * (sgMod + Bonus) * 0.85;
    QuickHeal_debug("Final Healing Bonus (1.5,2.0,2.5,3.0)", healMod15,healMod20,healMod25,healMod30);

    local InCombat = UnitAffectingCombat('player') or UnitAffectingCombat(Target);

    -- Spiritual Healing - Increases healing by 6% per rank on all spells
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,15);
    local shMod = 6*talentRank/100 + 1;
    QuickHeal_debug(string.format("Spiritual Healing modifier: %f", shMod));

    -- Improved Healing - Decreases mana usage by 5% per rank on LH,H and GH
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,11);
    local ihMod = 1 - 5*talentRank/100;
    QuickHeal_debug(string.format("Improved Healing modifier: %f", ihMod));

    local TargetIsHealthy = Health >= QuickHealVariables.RatioHealthyPriest;
    local ManaLeft = UnitMana('player');

    if TargetIsHealthy then
    QuickHeal_debug("Target is healthy",Health);
    end

    -- Detect proc of 'Hand of Edward the Odd' mace (next spell is instant cast)
    if QuickHeal_DetectBuff('player',"Spell_Holy_SearingLight") then
    QuickHeal_debug("BUFF: Hand of Edward the Odd (out of combat healing forced)");
    InCombat = false;
    end

    -- Detect Hazza'rah's Charm of Healing (Trinket from Zul'Gurub, Madness event)
    if QuickHeal_DetectBuff('player',"Spell_Holy_HealingAura") then
        QuickHeal_debug("BUFF: Hazza'rah buff (Greater Heal forced)");
        ForceGH = true;
    end

    -- Detect Inner Focus or Spirit of Redemption (hack ManaLeft and healneed)
    if QuickHeal_DetectBuff('player',"Spell_Frost_WindWalkOn",1) or QuickHeal_DetectBuff('player',"Spell_Holy_GreaterHeal") then
        QuickHeal_debug("Inner Focus or Spirit of Redemption active");
        ManaLeft = UnitManaMax('player'); -- Infinite mana
        healneed = 10^6; -- Deliberate overheal (mana is free)
    end

    -- Power Word: Shield on critically low targets
    -- Fires before any direct heal when Health (predicted, with incoming heals) is below threshold.
    -- PW:S is instant so it buys time for the follow-up heal to land.
    -- Press /qh heal a second time after PW:S lands to cast the direct heal.
    local RatioPWS = QuickHealVariables.RatioPWSThreshold or 0;
    if RatioPWS > 0 and Health < RatioPWS and UnitAffectingCombat('player') then
        if not QuickHeal_DetectBuff(Target, "Spell_Holy_PowerWordShield") and
           not QuickHeal_DetectDebuff(Target, "Spell_Holy_WeakenedSoul") then
            local SpellIDsPWS = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_POWER_WORD_SHIELD);
            local maxRankPWS = table.getn(SpellIDsPWS);
            if maxRankPWS >= 1 then
                -- Mana costs per rank (vanilla base values)
                local pwsMana = {50, 95, 160, 230, 290, 355, 440, 535, 655, 785};
                local pwsID = SpellIDsPWS[1]; -- fallback to rank 1
                for r = maxRankPWS, 1, -1 do
                    if SpellIDsPWS[r] and ManaLeft >= (pwsMana[r] or 9999) then
                        pwsID = SpellIDsPWS[r];
                        break;
                    end
                end
                QuickHeal_debug("Target critically low (" .. math.floor(Health*100) .. "%) - casting Power Word: Shield");
                return pwsID, 0; -- 0 HealSize: absorb, not a direct heal
            end
        end
    end

    if Overheal then
        QuickHeal_debug("MOOOOOOOOOOOOOOOOOOOOOOOOLTIPLIER");
    else

    end


    -- Get total healing modifier (factor) caused by healing target debuffs
    local HDB = QuickHeal_GetHealModifier(Target);
    QuickHeal_debug("Target debuff healing modifier",HDB);
    healneed = healneed/HDB;

    -- Get a list of ranks available for all spells
    local SpellIDsLH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_LESSER_HEAL);
    local SpellIDsH  = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_HEAL);
    local SpellIDsGH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_GREATER_HEAL);
    local SpellIDsFH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_FLASH_HEAL);
    local SpellIDsR = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_RENEW);

    local maxRankLH = table.getn(SpellIDsLH);
    local maxRankH  = table.getn(SpellIDsH);
    local maxRankGH = table.getn(SpellIDsGH);
    local maxRankFH = table.getn(SpellIDsFH);
    local maxRankR = table.getn(SpellIDsR);

    QuickHeal_debug(string.format("Found LH up to rank %d, H up top rank %d, GH up to rank %d, FH up to rank %d, and R up to max rank %d", maxRankLH, maxRankH, maxRankGH, maxRankFH, maxRankR));

    --Get max HealRanks that are allowed to be used
    local downRankFH = QuickHealVariables.DownrankValueFH or 0  -- rank for 1.5 sec heals
    local downRankNH = QuickHealVariables.DownrankValueNH or 0 -- rank for < 1.5 sec heals

    -- Compensation for health lost during combat
    local k=1.0;
    local K=1.0;
    if InCombat then
    k=0.9;
    K=0.8;
    end

    -- if healType = channel
    --jgpprint(healType)

    --if healType == "channel" and Overheal and healneed == 0 then
    --    SpellID = SpellIDsGH[5]; HealSize = 2080*shMod+healMod30;
    --end

    if healType == "channel" then
        QuickHeal_debug("CHANNEL HEAL: " .. healType)

        -- Find suitable SpellID based on the defined criteria
        if ForceGH and ManaLeft >= 351*ihMod and maxRankGH >=1 and downRankNH >= 8  and SpellIDsGH[1] then
            -- Hazza'rah buff is active so use only GH if that's possible
            QuickHeal_debug(string.format("Forcing GH with Hazza'rah buff"))
            if Health < QuickHealVariables.RatioFull then
                SpellID = SpellIDsGH[1]; HealSize = (838+healMod30)*shMod; 
                if healneed > (1066+healMod30     )*K*shMod and ManaLeft >= 432*ihMod and maxRankGH >=2 and downRankNH >= 9  and SpellIDsGH[2] then SpellID = SpellIDsGH[2]; HealSize = (1066+healMod30)*shMod end
                if healneed > (1328+healMod30     )*K*shMod and ManaLeft >= 517*ihMod and maxRankGH >=3 and downRankNH >= 10 and SpellIDsGH[3] then SpellID = SpellIDsGH[3]; HealSize = (1328+healMod30)*shMod end
                if healneed > (1632+healMod30     )*K*shMod and ManaLeft >= 622*ihMod and maxRankGH >=4 and downRankNH >= 11 and SpellIDsGH[4] then SpellID = SpellIDsGH[4]; HealSize = (1632+healMod30)*shMod end
                if healneed > (1768+healMod30     )*K*shMod and ManaLeft >= 674*ihMod and maxRankGH >=5 and downRankNH >= 12 and SpellIDsGH[5] then SpellID = SpellIDsGH[5]; HealSize = (1768+healMod30)*shMod end
            end
        elseif not InCombat or TargetIsHealthy or maxRankFH<1 then
            -- Not in combat or target is healthy so use the closest available mana efficient healing
            QuickHeal_debug(string.format("Not in combat or target healthy or no flash heal available, will use closest available LH, H or GH (not FH)"))
            if Health < QuickHealVariables.RatioFull then
                SpellID = SpellIDsLH[1]; HealSize = (53+healMod15*PF1)*shMod; -- Default to LH
                if healneed > (  84+healMod20*PF4 )*k*shMod and ManaLeft >=  45*ihMod and maxRankLH >=2 and downRankNH >= 2  and SpellIDsLH[2] then SpellID = SpellIDsLH[2]; HealSize = (84+healMod20*PF4)*shMod end
                if healneed > ( 154+healMod25*PF10)*K*shMod and ManaLeft >=  75*ihMod and maxRankLH >=3 and downRankNH >= 3  and SpellIDsLH[3] then SpellID = SpellIDsLH[3]; HealSize = (154+healMod25*PF10)*shMod end
                if healneed > ( 330+healMod30*PF18)*K*shMod and ManaLeft >= 155*ihMod and maxRankH  >=1 and downRankNH >= 4  and SpellIDsH[1]  then SpellID = SpellIDsH[1] ; HealSize = (330+healMod30*PF18)*shMod end
                if healneed > ( 476+healMod30     )*K*shMod and ManaLeft >= 205*ihMod and maxRankH  >=2 and downRankNH >= 5  and SpellIDsH[2]  then SpellID = SpellIDsH[2] ; HealSize = (476+healMod30)*shMod end
                if healneed > ( 624+healMod30     )*K*shMod and ManaLeft >= 255*ihMod and maxRankH  >=3 and downRankNH >= 6  and SpellIDsH[3]  then SpellID = SpellIDsH[3] ; HealSize = (624+healMod30)*shMod end
                if healneed > ( 667+healMod30     )*K*shMod and ManaLeft >= 305*ihMod and maxRankH  >=4 and downRankNH >= 7  and SpellIDsH[4]  then SpellID = SpellIDsH[4] ; HealSize = (667+healMod30)*shMod end
                if healneed > ( 838+healMod30     )*K*shMod and ManaLeft >= 370*ihMod and maxRankGH >=1 and downRankNH >= 8  and SpellIDsGH[1] then SpellID = SpellIDsGH[1]; HealSize = (838+healMod30)*shMod end
                if healneed > (1066+healMod30     )*K*shMod and ManaLeft >= 455*ihMod and maxRankGH >=2 and downRankNH >= 9  and SpellIDsGH[2] then SpellID = SpellIDsGH[2]; HealSize = (1066+healMod30)*shMod end
                if healneed > (1328+healMod30     )*K*shMod and ManaLeft >= 545*ihMod and maxRankGH >=3 and downRankNH >= 10 and SpellIDsGH[3] then SpellID = SpellIDsGH[3]; HealSize = (1328+healMod30)*shMod end
                if healneed > (1632+healMod30     )*K*shMod and ManaLeft >= 655*ihMod and maxRankGH >=4 and downRankNH >= 11 and SpellIDsGH[4] then SpellID = SpellIDsGH[4]; HealSize = (1632+healMod30)*shMod end
                if healneed > (1768+healMod30     )*K*shMod and ManaLeft >= 710*ihMod and maxRankGH >=5 and downRankNH >= 12 and SpellIDsGH[5] then SpellID = SpellIDsGH[5]; HealSize = (1768+healMod30)*shMod end
            end
        elseif not forceMaxHPS then
            -- In combat and target is unhealthy and player has flash heal
            QuickHeal_debug(string.format("In combat and target unhealthy and player has flash heal, will only use FH"));
            if Health < QuickHealVariables.RatioFull then
                SpellID = SpellIDsFH[1]; HealSize = (225+healMod15)*shMod; -- Default to FH
                if healneed > (297+healMod15)*k*shMod and ManaLeft >= 155 and maxRankFH >=2 and downRankFH >= 2 and SpellIDsFH[2] then SpellID = SpellIDsFH[2]; HealSize = (297+healMod15)*shMod end
                if healneed > (319+healMod15)*k*shMod and ManaLeft >= 185 and maxRankFH >=3 and downRankFH >= 3 and SpellIDsFH[3] then SpellID = SpellIDsFH[3]; HealSize = (319+healMod15)*shMod end
                if healneed > (387+healMod15)*k*shMod and ManaLeft >= 215 and maxRankFH >=4 and downRankFH >= 4 and SpellIDsFH[4] then SpellID = SpellIDsFH[4]; HealSize = (387+healMod15)*shMod end
                if healneed > (498+healMod15)*k*shMod and ManaLeft >= 265 and maxRankFH >=5 and downRankFH >= 5 and SpellIDsFH[5] then SpellID = SpellIDsFH[5]; HealSize = (498+healMod15)*shMod end
                if healneed > (618+healMod15)*k*shMod and ManaLeft >= 315 and maxRankFH >=6 and downRankFH >= 6 and SpellIDsFH[6] then SpellID = SpellIDsFH[6]; HealSize = (618+healMod15)*shMod end
                if healneed > (769+healMod15)*k*shMod and ManaLeft >= 380 and maxRankFH >=7 and downRankFH >= 7 and SpellIDsFH[7] then SpellID = SpellIDsFH[7]; HealSize = (769+healMod15)*shMod end
            end
        elseif forceMaxHPS then
            if ManaLeft >= 155 and maxRankFH >=2 and downRankFH >= 2 and SpellIDsFH[2] then SpellID = SpellIDsFH[2]; HealSize = (297+healMod15)*shMod end
            if ManaLeft >= 185 and maxRankFH >=3 and downRankFH >= 3 and SpellIDsFH[3] then SpellID = SpellIDsFH[3]; HealSize = (319+healMod15)*shMod end
            if ManaLeft >= 215 and maxRankFH >=4 and downRankFH >= 4 and SpellIDsFH[4] then SpellID = SpellIDsFH[4]; HealSize = (387+healMod15)*shMod end
            if ManaLeft >= 265 and maxRankFH >=5 and downRankFH >= 5 and SpellIDsFH[5] then SpellID = SpellIDsFH[5]; HealSize = (498+healMod15)*shMod end
            if ManaLeft >= 315 and maxRankFH >=6 and downRankFH >= 6 and SpellIDsFH[6] then SpellID = SpellIDsFH[6]; HealSize = (618+healMod15)*shMod end
            if ManaLeft >= 380 and maxRankFH >=7 and downRankFH >= 7 and SpellIDsFH[7] then SpellID = SpellIDsFH[7]; HealSize = (769+healMod15)*shMod end
        end
    end

    return SpellID,HealSize*HDB;
end

function QuickHeal_Priest_FindHealSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier, forceMaxHPS, forceMaxRank, hdb, incombat)
    local SpellID = nil;
    local HealSize = 0;
    local Overheal = false;
    local ForceGH = false;

    if multiplier ~= nil and multiplier > 1.0 then
        Overheal = true;
    end

    -- +Healing-PenaltyFactor = (1-((20-LevelLearnt)*0.0375)) for all spells learnt before level 20
    local PF1 = 0.2875;
    local PF4 = 0.4;
    local PF10 = 0.625;
    local PF18 = 0.925;

    -- Determine health and heal need of target
    local healneed = healDeficit * (multiplier or 1.0);
    local Health = healDeficit / maxhealth;

    local Bonus = 0
    if (AceLibrary and AceLibrary:HasInstance("ItemBonusLib-1.0")) then
        local itemBonus = AceLibrary("ItemBonusLib-1.0")
        Bonus = itemBonus:GetBonus("HEAL") or 0
        QuickHeal_debug(string.format("Equipment Healing Bonus: %d", Bonus))
    end

    -- Spiritual Guidance - Increases spell damage and healing by up to 5% (per rank) of your total Spirit.
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,12);
    local _,Spirit,_,_ = UnitStat('player',5);
    local sgMod = Spirit * 5*talentRank/100;
    QuickHeal_debug(string.format("Spiritual Guidance Bonus: %f", sgMod));

    -- Calculate healing bonus (0.85 = subspell efficiency factor, matches FindHealSpellToUse)
    local healMod15 = (1.5/3.5) * (sgMod + Bonus) * 0.85;
    local healMod20 = (2.0/3.5) * (sgMod + Bonus) * 0.85;
    local healMod25 = (2.5/3.5) * (sgMod + Bonus) * 0.85;
    local healMod30 = (3.0/3.5) * (sgMod + Bonus) * 0.85;
    QuickHeal_debug("Final Healing Bonus (1.5,2.0,2.5,3.0)", healMod15,healMod20,healMod25,healMod30);

    local InCombat = UnitAffectingCombat('player') or incombat;

    -- Spiritual Healing - Increases healing by 6% per rank on all spells
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,15);
    local shMod = 6*talentRank/100 + 1;
    QuickHeal_debug(string.format("Spiritual Healing modifier: %f", shMod));

    -- Improved Healing - Decreases mana usage by 5% per rank on LH,H and GH
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,11);
    local ihMod = 1 - 5*talentRank/100;
    QuickHeal_debug(string.format("Improved Healing modifier: %f", ihMod));

    local TargetIsHealthy = Health >= QuickHealVariables.RatioHealthyPriest;
    local ManaLeft = UnitMana('player');

    if TargetIsHealthy then
        QuickHeal_debug("Target is healthy",Health);
    end

    -- Detect proc of 'Hand of Edward the Odd' mace (next spell is instant cast)
    if QuickHeal_DetectBuff('player',"Spell_Holy_SearingLight") then
        QuickHeal_debug("BUFF: Hand of Edward the Odd (out of combat healing forced)");
        InCombat = false;
    end

    -- Detect Hazza'rah's Charm of Healing (Trinket from Zul'Gurub, Madness event)
    if QuickHeal_DetectBuff('player',"Spell_Holy_HealingAura") then
        QuickHeal_debug("BUFF: Hazza'rah buff (Greater Heal forced)");
        ForceGH = true;
    end

    -- Detect Inner Focus or Spirit of Redemption (hack ManaLeft and healneed)
    if QuickHeal_DetectBuff('player',"Spell_Frost_WindWalkOn",1) or QuickHeal_DetectBuff('player',"Spell_Holy_GreaterHeal") then
        QuickHeal_debug("Inner Focus or Spirit of Redemption active");
        ManaLeft = UnitManaMax('player'); -- Infinite mana
        healneed = 10^6; -- Deliberate overheal (mana is free)
    end

    -- Get total healing modifier (factor) caused by healing target debuffs
    --local HDB = QuickHeal_GetHealModifier(Target);
    --QuickHeal_debug("Target debuff healing modifier",HDB);
    healneed = healneed/hdb;

    -- Get a list of ranks available for all spells
    local SpellIDsLH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_LESSER_HEAL);
    local SpellIDsH  = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_HEAL);
    local SpellIDsGH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_GREATER_HEAL);
    local SpellIDsFH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_FLASH_HEAL);
    local SpellIDsR = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_RENEW);

    local maxRankLH = table.getn(SpellIDsLH);
    local maxRankH  = table.getn(SpellIDsH);
    local maxRankGH = table.getn(SpellIDsGH);
    local maxRankFH = table.getn(SpellIDsFH);
    local maxRankR = table.getn(SpellIDsR);

    QuickHeal_debug(string.format("Found LH up to rank %d, H up top rank %d, GH up to rank %d, FH up to rank %d, and R up to max rank %d", maxRankLH, maxRankH, maxRankGH, maxRankFH, maxRankR));

    --Get max HealRanks that are allowed to be used
    local downRankFH = QuickHealVariables.DownrankValueFH or 0  -- rank for 1.5 sec heals
    local downRankNH = QuickHealVariables.DownrankValueNH or 0 -- rank for < 1.5 sec heals

    -- Compensation for health lost during combat
    local k=1.0;
    local K=1.0;
    if InCombat then
        k=0.9;
        K=0.8;
    end

    if ForceGH and ManaLeft >= 351*ihMod and maxRankGH >=1 and downRankNH >= 8  and SpellIDsGH[1] then
            -- Hazza'rah buff is active so use only GH if that's possible
        QuickHeal_debug(string.format("Forcing GH with Hazza'rah buff"))
        if Health < QuickHealVariables.RatioFull then
            SpellID = SpellIDsGH[1]; HealSize = (838+healMod30)*shMod; 
            if healneed > (1066+healMod30     )*K*shMod and ManaLeft >= 432*ihMod and maxRankGH >=2 and downRankNH >= 9  and SpellIDsGH[2] then SpellID = SpellIDsGH[2]; HealSize = (1066+healMod30)*shMod end
            if healneed > (1328+healMod30     )*K*shMod and ManaLeft >= 517*ihMod and maxRankGH >=3 and downRankNH >= 10 and SpellIDsGH[3] then SpellID = SpellIDsGH[3]; HealSize = (1328+healMod30)*shMod end
            if healneed > (1632+healMod30     )*K*shMod and ManaLeft >= 622*ihMod and maxRankGH >=4 and downRankNH >= 11 and SpellIDsGH[4] then SpellID = SpellIDsGH[4]; HealSize = (1632+healMod30)*shMod end
            if healneed > (1768+healMod30     )*K*shMod and ManaLeft >= 674*ihMod and maxRankGH >=5 and downRankNH >= 12 and SpellIDsGH[5] then SpellID = SpellIDsGH[5]; HealSize = (1768+healMod30)*shMod end
        end
    elseif not forceMaxHPS then
        SpellID = SpellIDsLH[1]; HealSize = (53+healMod15*PF1)*shMod; -- Default to LH
        if healneed > (  84+healMod20*PF4 )*k*shMod and ManaLeft >=  45*ihMod and maxRankLH >=2 and downRankNH >= 2  and SpellIDsLH[2] then SpellID = SpellIDsLH[2]; HealSize = (  84+healMod20*PF4 )*shMod end
        if healneed > ( 154+healMod25*PF10)*K*shMod and ManaLeft >=  75*ihMod and maxRankLH >=3 and downRankNH >= 3  and SpellIDsLH[3] then SpellID = SpellIDsLH[3]; HealSize = ( 154+healMod25*PF10)*shMod end
        if healneed > ( 330+healMod30*PF18)*K*shMod and ManaLeft >= 155*ihMod and maxRankH  >=1 and downRankNH >= 4  and SpellIDsH[1]  then SpellID = SpellIDsH[1] ; HealSize = ( 330+healMod30*PF18)*shMod end
        if healneed > ( 476+healMod30     )*K*shMod and ManaLeft >= 205*ihMod and maxRankH  >=2 and downRankNH >= 5  and SpellIDsH[2]  then SpellID = SpellIDsH[2] ; HealSize = ( 476+healMod30     )*shMod end
        if healneed > ( 624+healMod30     )*K*shMod and ManaLeft >= 255*ihMod and maxRankH  >=3 and downRankNH >= 6  and SpellIDsH[3]  then SpellID = SpellIDsH[3] ; HealSize = ( 624+healMod30     )*shMod end
        if healneed > ( 667+healMod30     )*K*shMod and ManaLeft >= 305*ihMod and maxRankH  >=4 and downRankNH >= 7  and SpellIDsH[4]  then SpellID = SpellIDsH[4] ; HealSize = ( 667+healMod30     )*shMod end
        if healneed > ( 838+healMod30     )*K*shMod and ManaLeft >= 370*ihMod and maxRankGH >=1 and downRankNH >= 8  and SpellIDsGH[1] then SpellID = SpellIDsGH[1]; HealSize = ( 838+healMod30     )*shMod end
        if healneed > (1066+healMod30     )*K*shMod and ManaLeft >= 455*ihMod and maxRankGH >=2 and downRankNH >= 9  and SpellIDsGH[2] then SpellID = SpellIDsGH[2]; HealSize = (1066+healMod30     )*shMod end
        if healneed > (1328+healMod30	  )*K*shMod and ManaLeft >= 545*ihMod and maxRankGH >=3 and downRankNH >= 10 and SpellIDsGH[3] then SpellID = SpellIDsGH[3]; HealSize = (1328+healMod30     )*shMod end
        if healneed > (1632+healMod30     )*K*shMod and ManaLeft >= 655*ihMod and maxRankGH >=4 and downRankNH >= 11 and SpellIDsGH[4] then SpellID = SpellIDsGH[4]; HealSize = (1632+healMod30     )*shMod end
        if healneed > (1768+healMod30     )*K*shMod and ManaLeft >= 710*ihMod and maxRankGH >=5 and downRankNH >= 12 and SpellIDsGH[5] then SpellID = SpellIDsGH[5]; HealSize = (1768+healMod30     )*shMod end
    elseif forceMaxHPS then
        if ManaLeft >= 155 and maxRankFH >=2 and downRankFH >= 2 and SpellIDsFH[2] then SpellID = SpellIDsFH[2]; HealSize = (297+healMod15)*shMod end
        if ManaLeft >= 185 and maxRankFH >=3 and downRankFH >= 3 and SpellIDsFH[3] then SpellID = SpellIDsFH[3]; HealSize = (319+healMod15)*shMod end
        if ManaLeft >= 215 and maxRankFH >=4 and downRankFH >= 4 and SpellIDsFH[4] then SpellID = SpellIDsFH[4]; HealSize = (387+healMod15)*shMod end
        if ManaLeft >= 265 and maxRankFH >=5 and downRankFH >= 5 and SpellIDsFH[5] then SpellID = SpellIDsFH[5]; HealSize = (498+healMod15)*shMod end
        if ManaLeft >= 315 and maxRankFH >=6 and downRankFH >= 6 and SpellIDsFH[6] then SpellID = SpellIDsFH[6]; HealSize = (618+healMod15)*shMod end
        if ManaLeft >= 380 and maxRankFH >=7 and downRankFH >= 7 and SpellIDsFH[7] then SpellID = SpellIDsFH[7]; HealSize = (769+healMod15)*shMod end

    end

    -- Book of Prayer: if enabled and a direct heal was selected, ensure the spell type differs from last cast.
    -- Identifies the chosen type (FH/LH/H/GH), and if it matches the last cast, finds the best affordable
    -- alternative from the remaining types. Respects downrank limits and mana. ForceGH bypasses this.
    if QuickHealVariables.BookOfPrayerEnabled and healType == "channel" and SpellID and not ForceGH then
        local chosenType = 0;
        for r = 1, maxRankFH do if SpellIDsFH[r] == SpellID then chosenType = 1; break; end end
        if chosenType == 0 then for r = 1, maxRankLH do if SpellIDsLH[r] == SpellID then chosenType = 2; break; end end end
        if chosenType == 0 then for r = 1, maxRankH  do if SpellIDsH[r]  == SpellID then chosenType = 3; break; end end end
        if chosenType == 0 then for r = 1, maxRankGH do if SpellIDsGH[r] == SpellID then chosenType = 4; break; end end end

        local last = QuickHealVariables.BookOfPrayerLastSpell or 0;
        if last ~= 0 and chosenType ~= 0 and chosenType == last then
            local altID, altSize, altType = nil, 0, 0;

            -- FH (type 1): no ihMod; rank 1 always affordable
            if last ~= 1 and maxRankFH >= 1 then
                local fhMana = {85, 155, 185, 215, 265, 315, 380};
                local fhBase = {225, 297, 319, 387, 498, 618, 769};
                for r = maxRankFH, 1, -1 do
                    local mok = (r == 1) or (downRankFH >= r and ManaLeft >= (fhMana[r] or 9999));
                    if SpellIDsFH[r] and mok then
                        local sz = (fhBase[r] + healMod15) * shMod;
                        if sz > altSize then altID = SpellIDsFH[r]; altSize = sz; altType = 1; end
                        break;
                    end
                end
            end

            -- LH (type 2): rank 1 always affordable
            if last ~= 2 and maxRankLH >= 1 then
                local lhMana = {30, 45, 75};
                local lhBase = {(53+healMod15*PF1)*shMod, (84+healMod20*PF4)*shMod, (154+healMod25*PF10)*shMod};
                for r = maxRankLH, 1, -1 do
                    local mok = (r == 1) or (downRankNH >= r and ManaLeft >= (lhMana[r] or 9999)*ihMod);
                    if SpellIDsLH[r] and mok then
                        if lhBase[r] > altSize then altID = SpellIDsLH[r]; altSize = lhBase[r]; altType = 2; end
                        break;
                    end
                end
            end

            -- H (type 3): downRankNH offset = r+3 (H1=4, H2=5, H3=6, H4=7)
            if last ~= 3 and maxRankH >= 1 then
                local hMana = {155, 205, 255, 305};
                local hBase = {(330+healMod30*PF18)*shMod, (476+healMod30)*shMod, (624+healMod30)*shMod, (667+healMod30)*shMod};
                for r = maxRankH, 1, -1 do
                    if SpellIDsH[r] and downRankNH >= (r+3) and ManaLeft >= (hMana[r] or 9999)*ihMod then
                        if hBase[r] > altSize then altID = SpellIDsH[r]; altSize = hBase[r]; altType = 3; end
                        break;
                    end
                end
            end

            -- GH (type 4): downRankNH offset = r+7 (GH1=8 ... GH5=12)
            if last ~= 4 and maxRankGH >= 1 then
                local ghMana = {370, 455, 545, 655, 710};
                local ghBase = {(838+healMod30)*shMod, (1066+healMod30)*shMod, (1328+healMod30)*shMod, (1632+healMod30)*shMod, (1768+healMod30)*shMod};
                for r = maxRankGH, 1, -1 do
                    if SpellIDsGH[r] and downRankNH >= (r+7) and ManaLeft >= (ghMana[r] or 9999)*ihMod then
                        if ghBase[r] > altSize then altID = SpellIDsGH[r]; altSize = ghBase[r]; altType = 4; end
                        break;
                    end
                end
            end

            if altID then
                SpellID = altID;
                HealSize = altSize;
                chosenType = altType;
            end
        end
        QuickHealVariables.BookOfPrayerLastSpell = chosenType;
    end

    return SpellID,HealSize*HDB;
end

function QuickHeal_Priest_FindHoTSpellToUse(Target, healType, forceMaxRank)
    local SpellID = nil;
    local HealSize = 0;
    -- Return immediatly if no player needs healing
    if not Target then
        return SpellID,HealSize;
    end

    -- +Healing-PenaltyFactor = (1-((20-LevelLearnt)*0.0375)) for all spells learnt before level 20
    local PF1 = 0.2875;
    local PF4 = 0.4;
    local PF10 = 0.625;
    local PF18 = 0.925;

    -- Determine health and healneed of target
    local healneed;
    local Health;

    if QuickHeal_UnitHasHealthInfo(Target) then
        -- Full info available
        healneed = UnitHealthMax(Target) - UnitHealth(Target); -- Here you can integrate HealComm by adding "- HealComm:getHeal(UnitName(Target))" (this can autocancel your heals even when you don't want)
        Health = UnitHealth(Target) / UnitHealthMax(Target);
    else
        -- Estimate target health
        healneed = QuickHeal_EstimateUnitHealNeed(Target,true); -- needs HealComm implementation maybe
        Health = UnitHealth(Target)/100;
    end

    local Bonus = 0
    if (AceLibrary and AceLibrary:HasInstance("ItemBonusLib-1.0")) then
        local itemBonus = AceLibrary("ItemBonusLib-1.0")
        Bonus = itemBonus:GetBonus("HEAL") or 0
        QuickHeal_debug(string.format("Equipment Healing Bonus: %d", Bonus))
    end

    -- Spiritual Guidance - Increases spell damage and healing by up to 5% (per rank) of your total Spirit.
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,12);
    local _,Spirit,_,_ = UnitStat('player',5);
    local sgMod = Spirit * 5*talentRank/100;
    QuickHeal_debug(string.format("Spiritual Guidance Bonus: %f", sgMod));

    -- Calculate healing bonus
    local healMod15 = (1.5/3.5) * (sgMod + Bonus);
    local healMod20 = (2.0/3.5) * (sgMod + Bonus);
    local healMod25 = (2.5/3.5) * (sgMod + Bonus);
    local healMod30 = (3.0/3.5) * (sgMod + Bonus);
    QuickHeal_debug("Final Healing Bonus (1.5,2.0,2.5,3.0)", healMod15,healMod20,healMod25,healMod30);

    local InCombat = UnitAffectingCombat('player') or UnitAffectingCombat(Target);

    -- Spiritual Healing - Increases healing by 6% per rank on all spells
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,15);
    local shMod = 6*talentRank/100 + 1;
    QuickHeal_debug(string.format("Spiritual Healing modifier: %f", shMod));

    -- Improved Healing - Decreases mana usage by 5% per rank on LH,H and GH
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,11);
    local ihMod = 1 - 5*talentRank/100;
    QuickHeal_debug(string.format("Improved Healing modifier: %f", ihMod));

    local TargetIsHealthy = Health >= QuickHealVariables.RatioHealthyPriest;
    local ManaLeft = UnitMana('player');

    if TargetIsHealthy then
        QuickHeal_debug("Target is healthy",Health);
    end

    -- Detect proc of 'Hand of Edward the Odd' mace (next spell is instant cast)
    if QuickHeal_DetectBuff('player',"Spell_Holy_SearingLight") then
        QuickHeal_debug("BUFF: Hand of Edward the Odd (out of combat healing forced)");
        InCombat = false;
    end

    -- Detect Inner Focus or Spirit of Redemption (hack ManaLeft and healneed)
    if QuickHeal_DetectBuff('player',"Spell_Frost_WindWalkOn",1) or QuickHeal_DetectBuff('player',"Spell_Holy_GreaterHeal") then
        QuickHeal_debug("Inner Focus or Spirit of Redemption active");
        ManaLeft = UnitManaMax('player'); -- Infinite mana
        healneed = 10^6; -- Deliberate overheal (mana is free)
    end

    -- Get total healing modifier (factor) caused by healing target debuffs
    local HDB = QuickHeal_GetHealModifier(Target);
    QuickHeal_debug("Target debuff healing modifier",HDB);
    healneed = healneed/HDB;

    -- Get a list of ranks available for all spells
    local SpellIDsLH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_LESSER_HEAL);
    local SpellIDsH  = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_HEAL);
    local SpellIDsGH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_GREATER_HEAL);
    local SpellIDsFH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_FLASH_HEAL);
    local SpellIDsR = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_RENEW);

    local maxRankLH = table.getn(SpellIDsLH);
    local maxRankH  = table.getn(SpellIDsH);
    local maxRankGH = table.getn(SpellIDsGH);
    local maxRankFH = table.getn(SpellIDsFH);
    local maxRankR = table.getn(SpellIDsR);

    QuickHeal_debug(string.format("Found LH up to rank %d, H up top rank %d, GH up to rank %d, FH up to rank %d, and R up to max rank %d", maxRankLH, maxRankH, maxRankGH, maxRankFH, maxRankR));

    --Get max HealRanks that are allowed to be used
    local downRankFH = QuickHealVariables.DownrankValueFH or 0  -- rank for 1.5 sec heals
    local downRankNH = QuickHealVariables.DownrankValueNH or 0 -- rank for < 1.5 sec heals

    -- Compensation for health lost during combat
    local k=1.0;
    local K=1.0;
    if InCombat then
        k=0.9;
        K=0.8;
    end

    -- if healType = channel
    jgpprint(healType)

    if healType == "channel" then
        QuickHeal_debug("CHANNEL HEAL: " .. healType)
        -- Find suitable SpellID based on the defined criteria
        if not InCombat or TargetIsHealthy or maxRankFH<1 then
            -- Not in combat or target is healthy so use the closest available mana efficient healing
            QuickHeal_debug(string.format("Not in combat or target healthy or no flash heal available, will use closest available LH, H or GH (not FH)"))
            if Health < QuickHealVariables.RatioFull then
                SpellID = SpellIDsLH[1]; HealSize = (53+healMod15*PF1)*shMod; -- Default to LH
                if healneed > (  84+healMod20*PF4 )*k*shMod and ManaLeft >=  45*ihMod and maxRankLH >=2 and downRankNH >= 2  and SpellIDsLH[2] then SpellID = SpellIDsLH[2]; HealSize = (  84+healMod20*PF4 )*shMod end
                if healneed > ( 154+healMod25*PF10)*K*shMod and ManaLeft >=  75*ihMod and maxRankLH >=3 and downRankNH >= 3  and SpellIDsLH[3] then SpellID = SpellIDsLH[3]; HealSize = ( 154+healMod25*PF10)*shMod end
                if healneed > ( 330+healMod30*PF18)*K*shMod and ManaLeft >= 155*ihMod and maxRankH  >=1 and downRankNH >= 4  and SpellIDsH[1]  then SpellID = SpellIDsH[1] ; HealSize = ( 330+healMod30*PF18)*shMod end
                if healneed > ( 476+healMod30     )*K*shMod and ManaLeft >= 205*ihMod and maxRankH  >=2 and downRankNH >= 5  and SpellIDsH[2]  then SpellID = SpellIDsH[2] ; HealSize = ( 476+healMod30     )*shMod end
                if healneed > ( 624+healMod30     )*K*shMod and ManaLeft >= 255*ihMod and maxRankH  >=3 and downRankNH >= 6  and SpellIDsH[3]  then SpellID = SpellIDsH[3] ; HealSize = ( 624+healMod30     )*shMod end
                if healneed > ( 667+healMod30     )*K*shMod and ManaLeft >= 305*ihMod and maxRankH  >=4 and downRankNH >= 7  and SpellIDsH[4]  then SpellID = SpellIDsH[4] ; HealSize = ( 667+healMod30     )*shMod end
                if healneed > ( 838+healMod30     )*K*shMod and ManaLeft >= 370*ihMod and maxRankGH >=1 and downRankNH >= 8  and SpellIDsGH[1] then SpellID = SpellIDsGH[1]; HealSize = ( 838+healMod30     )*shMod end
                if healneed > (1066+healMod30     )*K*shMod and ManaLeft >= 455*ihMod and maxRankGH >=2 and downRankNH >= 9  and SpellIDsGH[2] then SpellID = SpellIDsGH[2]; HealSize = (1066+healMod30     )*shMod end
                if healneed > (1328+healMod30     )*K*shMod and ManaLeft >= 545*ihMod and maxRankGH >=3 and downRankNH >= 10 and SpellIDsGH[3] then SpellID = SpellIDsGH[3]; HealSize = (1328+healMod30     )*shMod end
                if healneed > (1632+healMod30     )*K*shMod and ManaLeft >= 655*ihMod and maxRankGH >=4 and downRankNH >= 11 and SpellIDsGH[4] then SpellID = SpellIDsGH[4]; HealSize = (1632+healMod30     )*shMod end
                if healneed > (1768+healMod30     )*K*shMod and ManaLeft >= 710*ihMod and maxRankGH >=5 and downRankNH >= 12 and SpellIDsGH[5] then SpellID = SpellIDsGH[5]; HealSize = (1768+healMod30     )*shMod end
            end
        else
            -- In combat and target is unhealthy and player has flash heal
            QuickHeal_debug(string.format("In combat and target unhealthy and player has flash heal, will only use FH"));
            if Health < QuickHealVariables.RatioFull then
                SpellID = SpellIDsFH[1]; HealSize = (225+healMod15)*shMod; -- Default to FH
                if healneed > (297+healMod15)*k*shMod and ManaLeft >= 155 and maxRankFH >=2 and downRankFH >= 2 and SpellIDsFH[2] then SpellID = SpellIDsFH[2]; HealSize = (297+healMod15)*shMod end
                if healneed > (319+healMod15)*k*shMod and ManaLeft >= 185 and maxRankFH >=3 and downRankFH >= 3 and SpellIDsFH[3] then SpellID = SpellIDsFH[3]; HealSize = (319+healMod15)*shMod end
                if healneed > (387+healMod15)*k*shMod and ManaLeft >= 215 and maxRankFH >=4 and downRankFH >= 4 and SpellIDsFH[4] then SpellID = SpellIDsFH[4]; HealSize = (387+healMod15)*shMod end
                if healneed > (498+healMod15)*k*shMod and ManaLeft >= 265 and maxRankFH >=5 and downRankFH >= 5 and SpellIDsFH[5] then SpellID = SpellIDsFH[5]; HealSize = (498+healMod15)*shMod end
                if healneed > (618+healMod15)*k*shMod and ManaLeft >= 315 and maxRankFH >=6 and downRankFH >= 6 and SpellIDsFH[6] then SpellID = SpellIDsFH[6]; HealSize = (618+healMod15)*shMod end
                if healneed > (769+healMod15)*k*shMod and ManaLeft >= 380 and maxRankFH >=7 and downRankFH >= 7 and SpellIDsFH[7] then SpellID = SpellIDsFH[7]; HealSize = (769+healMod15)*shMod end
            end
        end
    end

    if healType == "hot" then
        QuickHeal_debug(string.format("Spiritual Healing modifier: %f", shMod));
        --SpellID = SpellIDsR[1]; HealSize = 215*shMod+healMod15; -- Default to Renew

        --if Health < QuickHealVariables.RatioFull then
        --if Health > QuickHealVariables.RatioHealthyPriest then
        if not forceMaxRank then
            SpellID = SpellIDsR[1]; HealSize = (45+healMod30)*shMod; -- Default to Renew(Rank 1)
            if healneed > (100+healMod30)*k*shMod and ManaLeft >= 65  and maxRankR >=2  and SpellIDsR[2]  then SpellID = SpellIDsR[2];  HealSize = (100+healMod30)*shMod end
            if healneed > (175+healMod30)*k*shMod and ManaLeft >= 105 and maxRankR >=3  and SpellIDsR[3]  then SpellID = SpellIDsR[3];  HealSize = (175+healMod30)*shMod end
            if healneed > (245+healMod30)*k*shMod and ManaLeft >= 140 and maxRankR >=4  and SpellIDsR[4]  then SpellID = SpellIDsR[4];  HealSize = (245+healMod30)*shMod end
            if healneed > (270+healMod30)*k*shMod and ManaLeft >= 170 and maxRankR >=5  and SpellIDsR[5]  then SpellID = SpellIDsR[5];  HealSize = (270+healMod30)*shMod end
            if healneed > (340+healMod30)*k*shMod and ManaLeft >= 205 and maxRankR >=6  and SpellIDsR[6]  then SpellID = SpellIDsR[6];  HealSize = (340+healMod30)*shMod end
            if healneed > (435+healMod30)*k*shMod and ManaLeft >= 250 and maxRankR >=7  and SpellIDsR[7]  then SpellID = SpellIDsR[7];  HealSize = (435+healMod30)*shMod end
            if healneed > (555+healMod30)*k*shMod and ManaLeft >= 305 and maxRankR >=8  and SpellIDsR[8]  then SpellID = SpellIDsR[8];  HealSize = (555+healMod30)*shMod end
            if healneed > (690+healMod30)*k*shMod and ManaLeft >= 365 and maxRankR >=9  and SpellIDsR[9]  then SpellID = SpellIDsR[9];  HealSize = (690+healMod30)*shMod end
            if healneed > (825+healMod30)*k*shMod and ManaLeft >= 410 and maxRankR >=10 and SpellIDsR[10] then SpellID = SpellIDsR[10]; HealSize = (825+healMod30)*shMod end
        else
            SpellID = SpellIDsR[10]; HealSize = (825+healMod15)*shMod
            if maxRankR >=2  and SpellIDsR[2]  then SpellID = SpellIDsR[2];  HealSize = (100+healMod15)*shMod end
            if maxRankR >=3  and SpellIDsR[3]  then SpellID = SpellIDsR[3];  HealSize = (175+healMod15)*shMod end
            if maxRankR >=4  and SpellIDsR[4]  then SpellID = SpellIDsR[4];  HealSize = (245+healMod15)*shMod end
            if maxRankR >=5  and SpellIDsR[5]  then SpellID = SpellIDsR[5];  HealSize = (270+healMod15)*shMod end
            if maxRankR >=6  and SpellIDsR[6]  then SpellID = SpellIDsR[6];  HealSize = (340+healMod15)*shMod end
            if maxRankR >=7  and SpellIDsR[7]  then SpellID = SpellIDsR[7];  HealSize = (435+healMod15)*shMod end
            if maxRankR >=8  and SpellIDsR[8]  then SpellID = SpellIDsR[8];  HealSize = (555+healMod15)*shMod end
            if maxRankR >=9  and SpellIDsR[9]  then SpellID = SpellIDsR[9];  HealSize = (690+healMod15)*shMod end
            if maxRankR >=10 and SpellIDsR[10] then SpellID = SpellIDsR[10]; HealSize = (825+healMod15)*shMod end
        end
        --end
    end


    return SpellID,HealSize*HDB;
end

function QuickHeal_Priest_FindHoTSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier, forceMaxHPS, forceMaxRank, hdb, incombat)
    local SpellID = nil;
    local HealSize = 0;

    -- +Healing-PenaltyFactor = (1-((20-LevelLearnt)*0.0375)) for all spells learnt before level 20
    local PF1 = 0.2875;
    local PF4 = 0.4;
    local PF10 = 0.625;
    local PF18 = 0.925;

    -- Determine health and heal need of target
    local healneed = healDeficit * multiplier;
    local Health = healDeficit / maxhealth;

    local Bonus = 0
    if (AceLibrary and AceLibrary:HasInstance("ItemBonusLib-1.0")) then
        local itemBonus = AceLibrary("ItemBonusLib-1.0")
        Bonus = itemBonus:GetBonus("HEAL") or 0
        QuickHeal_debug(string.format("Equipment Healing Bonus: %d", Bonus))
    end

    -- Spiritual Guidance - Increases spell damage and healing by up to 5% (per rank) of your total Spirit.
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,12);
    local _,Spirit,_,_ = UnitStat('player',5);
    local sgMod = Spirit * 5*talentRank/100;
    QuickHeal_debug(string.format("Spiritual Guidance Bonus: %f", sgMod));

    -- Calculate healing bonus
    local healMod15 = (1.5/3.5) * (sgMod + Bonus);
    local healMod20 = (2.0/3.5) * (sgMod + Bonus);
    local healMod25 = (2.5/3.5) * (sgMod + Bonus);
    local healMod30 = (3.0/3.5) * (sgMod + Bonus);
    QuickHeal_debug("Final Healing Bonus (1.5,2.0,2.5,3.0)", healMod15,healMod20,healMod25,healMod30);

    local InCombat = UnitAffectingCombat('player') or incombat;

    -- Spiritual Healing - Increases healing by 6% per rank on all spells
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,15);
    local shMod = 6*talentRank/100 + 1;
    QuickHeal_debug(string.format("Spiritual Healing modifier: %f", shMod));

    -- Improved Healing - Decreases mana usage by 5% per rank on LH,H and GH
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,11);
    local ihMod = 1 - 5*talentRank/100;
    QuickHeal_debug(string.format("Improved Healing modifier: %f", ihMod));

    local TargetIsHealthy = Health >= QuickHealVariables.RatioHealthyPriest;
    local ManaLeft = UnitMana('player');

    if TargetIsHealthy then
        QuickHeal_debug("Target is healthy",Health);
    end

    -- Detect proc of 'Hand of Edward the Odd' mace (next spell is instant cast)
    if QuickHeal_DetectBuff('player',"Spell_Holy_SearingLight") then
        QuickHeal_debug("BUFF: Hand of Edward the Odd (out of combat healing forced)");
        InCombat = false;
    end

    -- Detect Inner Focus or Spirit of Redemption (hack ManaLeft and healneed)
    if QuickHeal_DetectBuff('player',"Spell_Frost_WindWalkOn",1) or QuickHeal_DetectBuff('player',"Spell_Holy_GreaterHeal") then
        QuickHeal_debug("Inner Focus or Spirit of Redemption active");
        ManaLeft = UnitManaMax('player'); -- Infinite mana
        healneed = 10^6; -- Deliberate overheal (mana is free)
    end

    -- Get total healing modifier (factor) caused by healing target debuffs
    --local HDB = QuickHeal_GetHealModifier(Target);
    --QuickHeal_debug("Target debuff healing modifier",HDB);
    healneed = healneed/hdb;

    -- if forceMaxRank, feed it an obnoxiously large heal requirement
    --if forceMaxRank then
    --    print('lollololool');
    --    healneed = 10000;
    --end

    -- Get a list of ranks available for all spells
    local SpellIDsLH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_LESSER_HEAL);
    local SpellIDsH  = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_HEAL);
    local SpellIDsGH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_GREATER_HEAL);
    local SpellIDsFH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_FLASH_HEAL);
    local SpellIDsR = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_RENEW);

    local maxRankLH = table.getn(SpellIDsLH);
    local maxRankH  = table.getn(SpellIDsH);
    local maxRankGH = table.getn(SpellIDsGH);
    local maxRankFH = table.getn(SpellIDsFH);
    local maxRankR = table.getn(SpellIDsR);

    QuickHeal_debug(string.format("Found LH up to rank %d, H up top rank %d, GH up to rank %d, FH up to rank %d, and R up to max rank %d", maxRankLH, maxRankH, maxRankGH, maxRankFH, maxRankR));

    --Get max HealRanks that are allowed to be used
    local downRankFH = QuickHealVariables.DownrankValueFH or 0  -- rank for 1.5 sec heals
    local downRankNH = QuickHealVariables.DownrankValueNH or 0 -- rank for < 1.5 sec heals

    -- Compensation for health lost during combat
    local k=1.0;
    local K=1.0;
    if InCombat then
        k=0.9;
        K=0.8;
    end

    SpellID = SpellIDsR[1]; HealSize = (45+healMod15)*shMod; -- Default to Renew(Rank 1)
    if healneed > (100+healMod30)*k*shMod and ManaLeft >= 65  and maxRankR >=2  and SpellIDsR[2]  then SpellID = SpellIDsR[2];  HealSize = (100+healMod30)*shMod end
    if healneed > (175+healMod30)*k*shMod and ManaLeft >= 105 and maxRankR >=3  and SpellIDsR[3]  then SpellID = SpellIDsR[3];  HealSize = (175+healMod30)*shMod end
    if healneed > (245+healMod30)*k*shMod and ManaLeft >= 140 and maxRankR >=4  and SpellIDsR[4]  then SpellID = SpellIDsR[4];  HealSize = (245+healMod30)*shMod end
    if healneed > (270+healMod30)*k*shMod and ManaLeft >= 170 and maxRankR >=5  and SpellIDsR[5]  then SpellID = SpellIDsR[5];  HealSize = (270+healMod30)*shMod end
    if healneed > (340+healMod30)*k*shMod and ManaLeft >= 205 and maxRankR >=6  and SpellIDsR[6]  then SpellID = SpellIDsR[6];  HealSize = (340+healMod30)*shMod end
    if healneed > (435+healMod30)*k*shMod and ManaLeft >= 250 and maxRankR >=7  and SpellIDsR[7]  then SpellID = SpellIDsR[7];  HealSize = (435+healMod30)*shMod end
    if healneed > (555+healMod30)*k*shMod and ManaLeft >= 305 and maxRankR >=8  and SpellIDsR[8]  then SpellID = SpellIDsR[8];  HealSize = (555+healMod30)*shMod end
    if healneed > (690+healMod30)*k*shMod and ManaLeft >= 365 and maxRankR >=9  and SpellIDsR[9]  then SpellID = SpellIDsR[9];  HealSize = (690+healMod30)*shMod end
    if healneed > (825+healMod30)*k*shMod and ManaLeft >= 410 and maxRankR >=10 and SpellIDsR[10] then SpellID = SpellIDsR[10]; HealSize = (825+healMod30)*shMod end

    return SpellID,HealSize*hdb;
end

function QuickHealSpellID(healneed)
    local SpellID = nil;
    local HealSize = 0;

    -- +Healing-PenaltyFactor = (1-((20-LevelLearnt)*0.0375)) for all spells learnt before level 20
    local PF1 = 0.2875;
    local PF4 = 0.4;
    local PF10 = 0.625;
    local PF18 = 0.925;

    -- Determine health and healneed of target
    --local healneed;
    --local Health;

    --if QuickHeal_UnitHasHealthInfo(Target) then
    --    -- Full info available
    --    healneed = UnitHealthMax(Target) - UnitHealth(Target); -- Here you can integrate HealComm by adding "- HealComm:getHeal(UnitName(Target))" (this can autocancel your heals even when you don't want)
    --
    --    Health = UnitHealth(Target) / UnitHealthMax(Target);
    --else
    --    -- Estimate target health
    --    healneed = QuickHeal_EstimateUnitHealNeed(Target,true); -- needs HealComm implementation maybe
    --
    --    Health = UnitHealth(Target)/100;
    --end

    local Bonus = 0
    if (AceLibrary and AceLibrary:HasInstance("ItemBonusLib-1.0")) then
        local itemBonus = AceLibrary("ItemBonusLib-1.0")
        Bonus = itemBonus:GetBonus("HEAL") or 0
        QuickHeal_debug(string.format("Equipment Healing Bonus: %d", Bonus))
    end

    -- Spiritual Guidance - Increases spell damage and healing by up to 5% (per rank) of your total Spirit.
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,12);
    local _,Spirit,_,_ = UnitStat('player',5);
    local sgMod = Spirit * 5*talentRank/100;
    QuickHeal_debug(string.format("Spiritual Guidance Bonus: %f", sgMod));

    -- Calculate healing bonus
    local healMod15 = (1.5/3.5) * (sgMod + Bonus);
    local healMod20 = (2.0/3.5) * (sgMod + Bonus);
    local healMod25 = (2.5/3.5) * (sgMod + Bonus);
    local healMod30 = (3.0/3.5) * (sgMod + Bonus);
    QuickHeal_debug("Final Healing Bonus (1.5,2.0,2.5,3.0)", healMod15,healMod20,healMod25,healMod30);

    local InCombat = UnitAffectingCombat('player');

    -- Spiritual Healing - Increases healing by 6% per rank on all spells
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,15);
    local shMod = 6*talentRank/100 + 1;
    QuickHeal_debug(string.format("Spiritual Healing modifier: %f", shMod));

    -- Improved Healing - Decreases mana usage by 5% per rank on LH,H and GH
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,11);
    local ihMod = 1 - 5*talentRank/100;
    QuickHeal_debug(string.format("Improved Healing modifier: %f", ihMod));

    local ManaLeft = UnitMana('player');

    --if TargetIsHealthy then
    --    QuickHeal_debug("Target is healthy",Health);
    --end

    -- Detect proc of 'Hand of Edward the Odd' mace (next spell is instant cast)
    if QuickHeal_DetectBuff('player',"Spell_Holy_SearingLight") then
        --QuickHeal_debug("BUFF: Hand of Edward the Odd (out of combat healing forced)");
        InCombat = false;
    end

    -- Detect Inner Focus or Spirit of Redemption (hack ManaLeft and healneed)
    if QuickHeal_DetectBuff('player',"Spell_Frost_WindWalkOn",1) or QuickHeal_DetectBuff('player',"Spell_Holy_GreaterHeal") then
        --QuickHeal_debug("Inner Focus or Spirit of Redemption active");
        ManaLeft = UnitManaMax('player'); -- Infinite mana
        healneed = 10^6; -- Deliberate overheal (mana is free)
    end

    -- Get a list of ranks available for all spells
    local SpellIDsLH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_LESSER_HEAL);
    local SpellIDsH  = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_HEAL);
    local SpellIDsGH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_GREATER_HEAL);

    local maxRankLH = table.getn(SpellIDsLH);
    local maxRankH  = table.getn(SpellIDsH);
    local maxRankGH = table.getn(SpellIDsGH);

    --QuickHeal_debug(string.format("Found LH up to rank %d, H up top rank %d, GH up to rank %d, FH up to rank %d, and R up to max rank %d", maxRankLH, maxRankH, maxRankGH, maxRankFH, maxRankR));

    -- Compensation for health lost during combat
    local k=1.0;
    local K=1.0;
    if InCombat then
        k=0.9;
        K=0.8;
    end

    -- if healType = channel
    --jgpprint(healType)

    SpellID = SpellIDsLH[1]; HealSize = (53+healMod15*PF1)*shMod; -- Default to LH
    if healneed > (  84+healMod20*PF4 )*k*shMod and ManaLeft >=  45*ihMod and maxRankLH >=2 and SpellIDsLH[2] then SpellID = SpellIDsLH[2]; HealSize = (  84+healMod20*PF4 )*shMod end
    if healneed > ( 154+healMod25*PF10)*K*shMod and ManaLeft >=  75*ihMod and maxRankLH >=3 and SpellIDsLH[3] then SpellID = SpellIDsLH[3]; HealSize = ( 154+healMod25*PF10)*shMod end
    if healneed > ( 330+healMod30*PF18)*K*shMod and ManaLeft >= 155*ihMod and maxRankH  >=1 and SpellIDsH[1]  then SpellID = SpellIDsH[1] ; HealSize = ( 330+healMod30*PF18)*shMod end
    if healneed > ( 476+healMod30     )*K*shMod and ManaLeft >= 205*ihMod and maxRankH  >=2 and SpellIDsH[2]  then SpellID = SpellIDsH[2] ; HealSize = ( 476+healMod30     )*shMod end
    if healneed > ( 624+healMod30     )*K*shMod and ManaLeft >= 255*ihMod and maxRankH  >=3 and SpellIDsH[3]  then SpellID = SpellIDsH[3] ; HealSize = ( 624+healMod30     )*shMod end
    if healneed > ( 667+healMod30     )*K*shMod and ManaLeft >= 305*ihMod and maxRankH  >=4 and SpellIDsH[4]  then SpellID = SpellIDsH[4] ; HealSize = ( 667+healMod30     )*shMod end
    if healneed > ( 838+healMod30     )*K*shMod and ManaLeft >= 370*ihMod and maxRankGH >=1 and SpellIDsGH[1] then SpellID = SpellIDsGH[1]; HealSize = ( 838+healMod30     )*shMod end
    if healneed > (1066+healMod30     )*K*shMod and ManaLeft >= 455*ihMod and maxRankGH >=2 and SpellIDsGH[2] then SpellID = SpellIDsGH[2]; HealSize = (1066+healMod30     )*shMod end
    if healneed > (1328+healMod30     )*K*shMod and ManaLeft >= 545*ihMod and maxRankGH >=3 and SpellIDsGH[3] then SpellID = SpellIDsGH[3]; HealSize = (1328+healMod30     )*shMod end
    if healneed > (1632+healMod30     )*K*shMod and ManaLeft >= 655*ihMod and maxRankGH >=4 and SpellIDsGH[4] then SpellID = SpellIDsGH[4]; HealSize = (1632+healMod30     )*shMod end
    if healneed > (1768+healMod30     )*K*shMod and ManaLeft >= 710*ihMod and maxRankGH >=5 and SpellIDsGH[5] then SpellID = SpellIDsGH[5]; HealSize = (1768+healMod30     )*shMod end

    --return SpellID;

    -- Get spell info
    local SpellName, SpellRank = GetSpellName(SpellID, BOOKTYPE_SPELL);
    if SpellRank == "" then
        SpellRank = nil
    end
    local SpellNameAndRank = SpellName .. (SpellRank and " (" .. SpellRank .. ")" or "");

    QuickHeal_debug("  Casting: " .. SpellNameAndRank .. " on " .. " NOPE " .. ", ID: " .. SpellID);

    local s = "Rank13";

    --msg = string.gsub(msg, "^%s*(.-)%s*$", "%1")

    local out = string.gsub(SpellRank,"%a+", "");
    --QuickHeal_debug("  out: " .. out);

    return SpellName, out;
end



function QuickHeal_Priest_FindPrayerOfHealingSpellToUse(Target, forceMaxRank)
    local SpellID = nil;
    local HealSize = 0;

    if not Target then
        return SpellID, HealSize;
    end

    local Bonus = 0
    if (AceLibrary and AceLibrary:HasInstance("ItemBonusLib-1.0")) then
        local itemBonus = AceLibrary("ItemBonusLib-1.0")
        Bonus = itemBonus:GetBonus("HEAL") or 0
    end

    -- Spiritual Guidance
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,12);
    local _,Spirit,_,_ = UnitStat('player',5);
    local sgMod = Spirit * 5*talentRank/100;

    -- Spiritual Healing
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,15);
    local shMod = 6*talentRank/100 + 1;

    -- PoH: 3.0s cast, AoE (5 targets), spell power coefficient = (3.0/3.5) / 5 per target
    local healModPoH = (3.0/3.5) * (sgMod + Bonus) / 5;

    local ManaLeft = UnitMana('player');

    -- Detect Inner Focus or Spirit of Redemption (free cast)
    if QuickHeal_DetectBuff('player',"Spell_Frost_WindWalkOn",1) or QuickHeal_DetectBuff('player',"Spell_Holy_GreaterHeal") then
        ManaLeft = UnitManaMax('player');
    end

    -- Determine healneed from target (worst-off member of the group)
    local healneed;
    if QuickHeal_UnitHasHealthInfo(Target) then
        healneed = UnitHealthMax(Target) - UnitHealth(Target);
    else
        healneed = QuickHeal_EstimateUnitHealNeed(Target, true);
    end

    local HDB = QuickHeal_GetHealModifier(Target);
    healneed = healneed / HDB;

    local SpellIDsPOH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_PRAYER_OF_HEALING);
    local maxRankPOH = table.getn(SpellIDsPOH);

    if maxRankPOH < 1 then
        return SpellID, HealSize;
    end

    local downRankNH = QuickHealVariables.DownrankValueNH or 0;

    if not forceMaxRank then
        SpellID = SpellIDsPOH[1]; HealSize = (301+healModPoH)*shMod;
        if healneed > (427+healModPoH)*shMod and ManaLeft >= 560  and maxRankPOH >= 2 and downRankNH >= 2 and SpellIDsPOH[2] then SpellID = SpellIDsPOH[2]; HealSize = (427+healModPoH)*shMod end
        if healneed > (558+healModPoH)*shMod and ManaLeft >= 710  and maxRankPOH >= 3 and downRankNH >= 3 and SpellIDsPOH[3] then SpellID = SpellIDsPOH[3]; HealSize = (558+healModPoH)*shMod end
        if healneed > (714+healModPoH)*shMod and ManaLeft >= 880  and maxRankPOH >= 4 and downRankNH >= 4 and SpellIDsPOH[4] then SpellID = SpellIDsPOH[4]; HealSize = (714+healModPoH)*shMod end
        if healneed > (910+healModPoH)*shMod and ManaLeft >= 1100 and maxRankPOH >= 5 and downRankNH >= 5 and SpellIDsPOH[5] then SpellID = SpellIDsPOH[5]; HealSize = (910+healModPoH)*shMod end
    else
        SpellID = SpellIDsPOH[1]; HealSize = (301+healModPoH)*shMod;
        if maxRankPOH >= 2 and SpellIDsPOH[2] then SpellID = SpellIDsPOH[2]; HealSize = (427+healModPoH)*shMod end
        if maxRankPOH >= 3 and SpellIDsPOH[3] then SpellID = SpellIDsPOH[3]; HealSize = (558+healModPoH)*shMod end
        if maxRankPOH >= 4 and SpellIDsPOH[4] then SpellID = SpellIDsPOH[4]; HealSize = (714+healModPoH)*shMod end
        if maxRankPOH >= 5 and SpellIDsPOH[5] then SpellID = SpellIDsPOH[5]; HealSize = (910+healModPoH)*shMod end
    end

    return SpellID, HealSize * HDB;
end

function QuickHeal_Priest_FindPrayerOfHealingSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier, forceMaxHPS, forceMaxRank, hdb, incombat)
    local SpellID = nil;
    local HealSize = 0;

    local healneed = healDeficit * multiplier;

    local Bonus = 0
    if (AceLibrary and AceLibrary:HasInstance("ItemBonusLib-1.0")) then
        local itemBonus = AceLibrary("ItemBonusLib-1.0")
        Bonus = itemBonus:GetBonus("HEAL") or 0
    end

    -- Spiritual Guidance
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,12);
    local _,Spirit,_,_ = UnitStat('player',5);
    local sgMod = Spirit * 5*talentRank/100;

    -- Spiritual Healing
    local _,_,_,_,talentRank,_ = GetTalentInfo(2,15);
    local shMod = 6*talentRank/100 + 1;

    -- PoH: 3.0s cast, AoE (5 targets), spell power coefficient = (3.0/3.5) / 5 per target
    local healModPoH = (3.0/3.5) * (sgMod + Bonus) / 5;

    local ManaLeft = UnitMana('player');

    -- Detect Inner Focus or Spirit of Redemption (free cast)
    if QuickHeal_DetectBuff('player',"Spell_Frost_WindWalkOn",1) or QuickHeal_DetectBuff('player',"Spell_Holy_GreaterHeal") then
        ManaLeft = UnitManaMax('player');
        healneed = 10^6;
    end

    healneed = healneed / hdb;

    local SpellIDsPOH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_PRAYER_OF_HEALING);
    local maxRankPOH = table.getn(SpellIDsPOH);

    if maxRankPOH < 1 then
        return SpellID, HealSize;
    end

    local downRankNH = QuickHealVariables.DownrankValueNH or 0;

    if not forceMaxRank then
        SpellID = SpellIDsPOH[1]; HealSize = (301+healModPoH)*shMod;
        if healneed > (427+healModPoH)*shMod and ManaLeft >= 560  and maxRankPOH >= 2 and downRankNH >= 2 and SpellIDsPOH[2] then SpellID = SpellIDsPOH[2]; HealSize = (427+healModPoH)*shMod end
        if healneed > (558+healModPoH)*shMod and ManaLeft >= 710  and maxRankPOH >= 3 and downRankNH >= 3 and SpellIDsPOH[3] then SpellID = SpellIDsPOH[3]; HealSize = (558+healModPoH)*shMod end
        if healneed > (714+healModPoH)*shMod and ManaLeft >= 880  and maxRankPOH >= 4 and downRankNH >= 4 and SpellIDsPOH[4] then SpellID = SpellIDsPOH[4]; HealSize = (714+healModPoH)*shMod end
        if healneed > (910+healModPoH)*shMod and ManaLeft >= 1100 and maxRankPOH >= 5 and downRankNH >= 5 and SpellIDsPOH[5] then SpellID = SpellIDsPOH[5]; HealSize = (910+healModPoH)*shMod end
    else
        SpellID = SpellIDsPOH[1]; HealSize = (301+healModPoH)*shMod;
        if maxRankPOH >= 2 and SpellIDsPOH[2] then SpellID = SpellIDsPOH[2]; HealSize = (427+healModPoH)*shMod end
        if maxRankPOH >= 3 and SpellIDsPOH[3] then SpellID = SpellIDsPOH[3]; HealSize = (558+healModPoH)*shMod end
        if maxRankPOH >= 4 and SpellIDsPOH[4] then SpellID = SpellIDsPOH[4]; HealSize = (714+healModPoH)*shMod end
        if maxRankPOH >= 5 and SpellIDsPOH[5] then SpellID = SpellIDsPOH[5]; HealSize = (910+healModPoH)*shMod end
    end

    return SpellID, HealSize * hdb;
end

function QuickHeal_Command_Priest(msg)

    --if PlayerClass == "priest" then
    --  writeLine("PRIEST", 0, 1, 0);
    --end

    local _, _, arg1, arg2, arg3 = string.find(msg, "%s?(%w+)%s?(%w+)%s?(%w+)")

    -- match 3 arguments
    if arg1 ~= nil and arg2 ~= nil and arg3 ~= nil then
        if arg1 == "player" or arg1 == "target" or arg1 == "targettarget" or arg1 == "party" or arg1 == "subgroup" or arg1 == "mt" or arg1 == "nonmt" then
            if arg2 == "heal" and arg3 == "max" then
                --writeLine(QuickHealData.name .. " qh " .. arg1 .. " HEAL(maxHPS)", 0, 1, 0);
                QuickHeal(arg1, nil, nil, true);
                return;
            end
            if arg2 == "poh" and arg3 == "max" then
                QuickPrayerOfHealing(arg1, nil, nil, true);
                return;
            end
            if arg2 == "hot" and arg3 == "fh" then
                --writeLine(QuickHealData.name .. " qh " .. arg1 .. " HOT(max rank & no hp check)", 0, 1, 0);
                QuickHOT(arg1, nil, nil, true, true);
                return;
            end
            if arg2 == "hot" and arg3 == "max" then
                --writeLine(QuickHealData.name .. " qh " .. arg1 .. " HOT(max rank)", 0, 1, 0);
                QuickHOT(arg1, nil, nil, true, false);
                return;
            end
        end
    end

    -- match 2 arguments
    local _, _, arg4, arg5= string.find(msg, "%s?(%w+)%s?(%w+)")

    if arg4 ~= nil and arg5 ~= nil then
        if arg4 == "debug" then
            if arg5 == "on" then
                QHV.DebugMode = true;
                --writeLine(QuickHealData.name .. " debug mode enabled", 0, 0, 1);
                return;
            elseif arg5 == "off" then
                QHV.DebugMode = false;
                --writeLine(QuickHealData.name .. " debug mode disabled", 0, 0, 1);
                return;
            end
        end
        if arg4 == "heal" and arg5 == "max" then
            --writeLine(QuickHealData.name .. " HEAL (max)", 0, 1, 0);
            QuickHeal(nil, nil, nil, true);
            return;
        end
        if arg4 == "poh" and arg5 == "max" then
            QuickPrayerOfHealing(nil, nil, nil, true);
            return;
        end
        if arg4 == "hot" and arg5 == "max" then
            --writeLine(QuickHealData.name .. " HOT (max)", 0, 1, 0);
            QuickHOT(nil, nil, nil, true, false);
            return;
        end
        if arg4 == "hot" and arg5 == "fh" then
            --writeLine(QuickHealData.name .. " FH (max rank & no hp check)", 0, 1, 0);
            QuickHOT(nil, nil, nil, true, true);
            return;
        end
        if arg4 == "player" or arg4 == "target" or arg4 == "targettarget" or arg4 == "party" or arg4 == "subgroup" or arg4 == "mt" or arg4 == "nonmt" then
            if arg5 == "hot" then
                --writeLine(QuickHealData.name .. " qh " .. arg1 .. " HOT", 0, 1, 0);
                QuickHOT(arg1, nil, nil, false, false);
                return;
            end
            if arg5 == "heal" then
                --writeLine(QuickHealData.name .. " qh " .. arg1 .. " HEAL", 0, 1, 0);
                QuickHeal(arg1, nil, nil, false);
                return;
            end
            if arg5 == "poh" then
                QuickPrayerOfHealing(arg4, nil, nil, false);
                return;
            end
        end
    end

    -- match 1 argument
    local cmd = string.lower(msg)

    if cmd == "cfg" then
        QuickHeal_ToggleConfigurationPanel();
        return;
    end

    if cmd == "toggle" then
        QuickHeal_Toggle_Healthy_Threshold();
        return;
    end

    if cmd == "downrank" or cmd == "dr" then
        ToggleDownrankWindow()
        return;
    end

    if cmd == "tanklist" or cmd == "tl" then
        QH_ShowHideMTListUI();
        return;
    end

    if cmd == "reset" then
        QuickHeal_SetDefaultParameters();
        writeLine(QuickHealData.name .. " reset to default configuration", 0, 0, 1);
        QuickHeal_ToggleConfigurationPanel();
        QuickHeal_ToggleConfigurationPanel();
        return;
    end

    if cmd == "heal" then
        --writeLine(QuickHealData.name .. " HEAL", 0, 1, 0);
        QuickHeal();
        return;
    end

    if cmd == "hot" then
        --writeLine(QuickHealData.name .. " HOT", 0, 1, 0);
        QuickHOT();
        return;
    end

    if cmd == "poh" then
        QuickPrayerOfHealing();
        return;
    end

    -- /qh bop  — toggle Book of Prayer rotation
    if cmd == "bop" then
        QuickHealVariables.BookOfPrayerEnabled = not QuickHealVariables.BookOfPrayerEnabled;
        QuickHealVariables.BookOfPrayerLastSpell = 0;
        if QuickHealVariables.BookOfPrayerEnabled then
            writeLine(QuickHealData.name .. " Book of Prayer rotation ENABLED (FH -> LH -> H cycle).");
        else
            writeLine(QuickHealData.name .. " Book of Prayer rotation DISABLED.");
        end
        return;
    end

    -- /qh pws [0-100]  — set the Power Word: Shield threshold (0 = disabled)
    local _, _, pwsArg = string.find(msg, "^pws%s+(%d+)$");
    if pwsArg then
        local val = tonumber(pwsArg) / 100;
        QuickHealVariables.RatioPWSThreshold = val;
        if val == 0 then
            writeLine(QuickHealData.name .. " Power Word: Shield auto-cast disabled.");
        else
            writeLine(QuickHealData.name .. " Power Word: Shield will be cast when target health is below " .. pwsArg .. "%.");
        end
        return;
    end

    if cmd == "" then
        --writeLine(QuickHealData.name .. " qh", 0, 1, 0);
        QuickHeal(nil);
        return;
    elseif cmd == "player" or cmd == "target" or cmd == "targettarget" or cmd == "party" or cmd == "subgroup" or cmd == "mt" or cmd == "nonmt" then
        --writeLine(QuickHealData.name .. " qh " .. cmd, 0, 1, 0);
        QuickHeal(cmd);
        return;
    end

    -- Print usage information if arguments do not match
    --writeLine(QuickHealData.name .. " Usage:");
    writeLine("== QUICKHEAL USAGE : PRIEST ==");
    writeLine("/qh cfg - Opens up the configuration panel.");
    writeLine("/qh toggle - Switches between High HPS and Normal HPS.  Heals (Healthy Threshold 0% or 100%).");
    writeLine("/qh downrank | dr - Opens the slider to limit QuickHeal to constrain healing to lower ranks.");
    writeLine("/qh tanklist | tl - Toggles display of the main tank list UI.");
    writeLine("/qh [mask] [type] [mod] - Heals the party/raid member that most needs it with the best suited healing spell.");
    writeLine(" [mask] constrains healing pool to:");
    writeLine("  [player] yourself");
    writeLine("  [target] your target");
    writeLine("  [targettarget] your target's target");
    writeLine("  [party] your party");
    writeLine("  [mt] main tanks (defined in the configuration panel)");
    writeLine("  [nonmt] everyone but the main tanks");
    writeLine("  [subgroup] raid subgroups (defined in the configuration panel)");

    writeLine(" [type] specifies the use of a [heal], [hot], or [poh]");
    writeLine("  [heal] channeled heal");
    writeLine("  [hot]  heal over time");
    writeLine("  [poh]  Prayer of Healing (AOE group heal - targets the group with highest total deficit)");
    writeLine(" [mod] (optional) modifies [hot] or [heal] options:");
    writeLine("  [heal] modifier options:");
    writeLine("   [max] applies maximum rank [heal] to subgroup members that have <100% health");
    writeLine("  [hot] modifier options:");
    writeLine("   [max] applies maximum rank [hot] to subgroup members that have <100% health and no hot applied");
    writeLine("   [fh] applies maximum rank [hot] to subgroup members that have no hot applied regardless of health status");

    writeLine("/qh pws [0-100] - Set the health % threshold below which Power Word: Shield is cast before a direct heal (0 = disabled, default 25).");
    writeLine("/qh bop - Toggle Book of Prayer rotation (cycles FH -> LH -> H to trigger 30% mana refund).");
    writeLine("/qh reset - Reset configuration to default parameters for all classes.");
end



