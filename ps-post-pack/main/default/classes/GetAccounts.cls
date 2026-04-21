/**
 * @description       : 
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             : 
 * @last modified on  : 04-09-2026
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
**/
public with sharing class GetAccounts {
    @AuraEnabled(cacheable = true)
    public static Account getAccountDetails(Id accountId) {
        Account accountDetails = [SELECT Id, Name,PersonEmail,Phone, BillingCity, BillingState, BillingPostalCode, BillingStreet, PersonContactId,
            (SELECT Serial_Number__c,Atrial_Risk_Score__c,Pacing_Performance_Score__c,Battery_Score__c,Last_Transmission__c,Cadence__c FROM Contacts WHERE AccountId =: accountId LIMIT 1)
            FROM Account
            WHERE Id =: accountId
            LIMIT 1
        ];

        return accountDetails;
    }

    @AuraEnabled(cacheable = true)
    public static Asset getAssetDetails(Id accountId) {
        Asset assetDetails = new Asset();
        List<Contact> conList = [SELECT Id,Serial_Number__c from Contact WHERE AccountId =: accountId and Serial_Number__c != NULL LIMIT 1];
        if(!conList.isEmpty()){
            assetDetails = [SELECT Id,Implant_Site__c,Product2.Name FROM Asset WHERE AccountId =: accountId and Implant_Site__c != NULL and SerialNumber =: conList[0].Serial_Number__c Limit 1];
        }
        return assetDetails;
    }
}