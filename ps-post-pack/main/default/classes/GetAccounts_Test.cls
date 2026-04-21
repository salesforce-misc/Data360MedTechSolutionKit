@IsTest
public class GetAccounts_Test {

    /* =====================================================
       🔧 TEST DATA SETUP
       ===================================================== */
    private static Account createTestData() {

        Account acc = new Account(
            Name = 'Test Account',
            Phone = '1234567890',
            BillingCity = 'Austin',
            BillingState = 'TX',
            BillingPostalCode = '78701',
            BillingStreet = '123 Main St'
        );
        insert acc;

        Contact con = new Contact(
            LastName = 'Test Contact',
            AccountId = acc.Id,
            Serial_Number__c = 'SN-12345',
            Atrial_Risk_Score__c = 2,
            Pacing_Performance_Score__c = 3,
            Battery_Score__c = 90,
            Last_Transmission__c = Datetime.now(),
            Cadence__c = 7
        );
        insert con;

        Product2 prod = new Product2(
            Name = 'Test Device',
            IsActive = true
        );
        insert prod;

        Asset asset = new Asset(
            Name = 'Test Asset',
            AccountId = acc.Id,
            ContactId = con.Id,
            Product2Id = prod.Id,
            SerialNumber = 'SN-12345',
            Implant_Site__c = 'Left Arm'
        );
        insert asset;

        return acc;
    }

    /* =====================================================
       1️⃣ TEST: getAccountDetails
       ===================================================== */
    @IsTest
    static void testGetAccountDetails() {

        Account acc = createTestData();

        Test.startTest();
        Account result = GetAccounts.getAccountDetails(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(acc.Id, result.Id);
        System.assertEquals('Test Account', result.Name);

        System.assert(result.Contacts.size() > 0);
        System.assertEquals('SN-12345', result.Contacts[0].Serial_Number__c);
    }

    /* =====================================================
       2️⃣ TEST: getAssetDetails (SUCCESS)
       ===================================================== */
    @IsTest
    static void testGetAssetDetails_success() {

        Account acc = createTestData();

        Test.startTest();
        Asset result = GetAccounts.getAssetDetails(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals('Left Arm', result.Implant_Site__c);
        System.assertEquals('Test Device', result.Product2.Name);
    }

    /* =====================================================
       3️⃣ TEST: getAssetDetails (NO SERIAL)
       ===================================================== */
    @IsTest
    static void testGetAssetDetails_noSerial() {

        Account acc = new Account(Name = 'No Serial Account');
        insert acc;

        Contact con = new Contact(
            LastName = 'No Serial',
            AccountId = acc.Id
        );
        insert con;

        Test.startTest();
        Asset result = GetAccounts.getAssetDetails(acc.Id);
        Test.stopTest();

        System.assertEquals(null, result.Id);
    }

    /* =====================================================
       4️⃣ TEST: getAccountDetails (NO CONTACT)
       ===================================================== */
    @IsTest
    static void testGetAccountDetails_noContact() {

        Account acc = new Account(Name = 'No Contact Account');
        insert acc;

        Test.startTest();
        Account result = GetAccounts.getAccountDetails(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(0, result.Contacts.size());
    }
}