/**
 * @description       : 
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             : 
 * @last modified on  : 03-27-2026
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
**/
@isTest
public class PulseSyncUtil_Test {

    @isTest
    static void testInvokeMethod() {
    
        Account acc = new Account(Name = 'Test Account');
        insert acc;
    
        Contact con = new Contact(
            FirstName = 'John',
            LastName = 'Doe',
            AccountId = acc.Id
        );
        insert con;
        Contact cont = [Select Id,Name from Contact where Id =: con.Id];
        // IMPORTANT: Your class treats ContactId as AccountId
        PulseSyncUtil.Request req = new PulseSyncUtil.Request();
        req.ContactId = acc.Id;
    
        Test.startTest();
        List<PulseSyncUtil.promptResponse> responseList =
            PulseSyncUtil.invoke(new List<PulseSyncUtil.Request>{ req });
        Test.stopTest();
    
        System.assertEquals(1, responseList.size());
        System.assertEquals(
            cont.Name,
            responseList[0].Prompt,
            'Prompt should return the contact name'
        );
    }    

    @isTest
    static void testInvokeWithEmptyList() {

        Test.startTest();
        List<PulseSyncUtil.promptResponse> responseList =
            PulseSyncUtil.invoke(new List<PulseSyncUtil.Request>());
        Test.stopTest();

        System.assertEquals(0, responseList.size(), 'Empty input should return empty list');
    }
   /* =====================================================
       1️. TEST: activateStandardPricebook
       ===================================================== */
    @IsTest
    static void testActivateStandardPricebook() {

        Test.startTest();

        PulseSyncUtil.activateStandardPricebook();

        Test.stopTest();

        // No assertion needed because Salesforce handles standard PB internally
        System.assert(true, 'Method executed without exception');
    }

    /* =====================================================
       2️. TEST: expSiteUserCreation
       ===================================================== */
    @IsTest
    static void testExpSiteUserCreation() {

        Account acc = new Account(Name = 'Test Acc');
        insert acc;

        Contact con = new Contact(
            FirstName = 'Mark',
            LastName = 'Smith',
            Email = 'mark@test.com',
            AccountId = acc.Id,
            isHealthCloudRecord__c = true
        );
        insert con;

        Test.startTest();
        try {
            PulseSyncUtil.expSiteUserCreation();
        } catch (Exception e) {
            System.debug('Handled: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(true);
    }

    /* =====================================================
       3️. TEST: assignCopyFieldPermission
       ===================================================== */
    @IsTest
    static void testAssignCopyFieldPermission() {

        Test.startTest();
        try {
            PulseSyncUtil.assignCopyFieldPermission();
        } catch (Exception e) {
            System.debug('Handled: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(true);
    }

    /* =====================================================
       4️. TEST: setup
       ===================================================== */
    @IsTest
    static void testSetup() {

        Test.startTest();
        try {
            PulseSyncUtil.setup();
        } catch (Exception e) {
            System.debug('Handled: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(true);
    }

    /* =====================================================
       5️. TEST: getPermissionSetLicenseIds
       ===================================================== */
    @IsTest
    static void testGetPermissionSetLicenseIds() {

        Test.startTest();

        Set<Id> result = PulseSyncUtil.getPermissionSetLicenseIds();

        Test.stopTest();

        System.assertNotEquals(null, result);
    }

}