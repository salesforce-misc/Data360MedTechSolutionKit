/**
 * @description       : 
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             : 
 * @last modified on  : 03-25-2026
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
**/
delete [SELECT Id FROM Case WHERE CreatedDate = TODAY];
delete [SELECT id FROM Entitlement WHERE CreatedDate = TODAY];
delete [SELECT Id FROM MedicationRequest WHERE CreatedDate = TODAY];
delete [SELECT Id FROM Medication WHERE CreatedDate = TODAY];
delete [SELECT Id FROM AllergyIntolerance WHERE CreatedDate = TODAY];
delete [SELECT Id FROM HealthCondition WHERE CreatedDate = TODAY];
delete [SELECT Id FROM PatientMedicalProcedure WHERE CreatedDate = TODAY];
delete [SELECT Id FROM Account WHERE CreatedDate = TODAY];
delete [SELECT Id FROM Product2 WHERE CreatedDate = TODAY];
delete [SELECT Id FROM Pricebook2 WHERE CreatedDate = TODAY];
delete [SELECT Id FROM CodeSetBundle WHERE CreatedDate = TODAY];
delete [SELECT Id FROM CodeSet WHERE CreatedDate = TODAY];
delete [SELECT id FROM Asset WHERE CreatedDate = TODAY];
delete [SELECT id FROM Entitlement WHERE CreatedDate = TODAY];
System.debug('Deleted the data successfully');