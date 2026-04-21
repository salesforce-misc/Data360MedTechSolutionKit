/**
 * @description       : 
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             : 
 * @last modified on  : 02-26-2026
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
**/
MessagingChannel channel = [SELECT Id, IsActive FROM MessagingChannel WHERE DeveloperName='ESA_Channel' LIMIT 1];
channel.IsActive = true;
update channel;