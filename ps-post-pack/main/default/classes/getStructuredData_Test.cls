@IsTest
public class getStructuredData_Test {

    /* =====================================================
       🔧 COMMON TEST DATA (REAL RECORDS)
       ===================================================== */
    private static Account createAccountWithData(String name) {

        Account acc = new Account(Name = name);
        insert acc;

        Contact con = new Contact(
            LastName = name,
            AccountId = acc.Id,
            Implant_Date__c = Date.today()
        );
        insert con;

        // REAL Asset (Fix for stub error)
        Asset asset = new Asset(
            Name = 'Test Device',
            AccountId = acc.Id,
            SerialNumber = 'SN-TEST-001'
        );
        insert asset;

        return acc;
    }

    /* =====================================================
       1️. TEST: HomeMonitor
       ===================================================== */
    @IsTest
    static void testHomeMonitor() {

        Account acc = createAccountWithData('HM Test');

        getStructuredData.Request req = new getStructuredData.Request();
        req.AccountId = acc.Id;
        req.RequestType = 'HomeMonitor';

        Test.startTest();

        registerStubs(new HomeMonitorStub());

        List<getStructuredData.promptResponse> results =
            getStructuredData.invoke(new List<getStructuredData.Request>{ req });

        Test.stopTest();

        System.assert(!results.isEmpty(), 'Response should not be empty');
        System.assert(results[0].Structured_Data.contains('Home_Monitor'));
    }

    /* =====================================================
       2️. TEST: WarrantyCoverage
       ===================================================== */
    @IsTest
    static void testWarrantyCoverage() {

        Account acc = createAccountWithData('WR Test');

        getStructuredData.Request req = new getStructuredData.Request();
        req.AccountId = acc.Id;
        req.RequestType = 'WarrantyCoverage';

        Test.startTest();

        registerStubs(new WarrantyCoverageStub());

        List<getStructuredData.promptResponse> results =
            getStructuredData.invoke(new List<getStructuredData.Request>{ req });

        Test.stopTest();

        System.assert(!results.isEmpty());
        System.assert(results[0].Structured_Data.contains('Product_Data'));
        System.assert(results[0].Structured_Data.contains('Entitlement_Data'));
    }

    /* =====================================================
       3️. TEST: MonitorTransmitting
       ===================================================== */
    @IsTest
    static void testMonitorTransmitting() {

        Account acc = createAccountWithData('MT Test');

        getStructuredData.Request req = new getStructuredData.Request();
        req.AccountId = acc.Id;
        req.RequestType = 'MonitorTransmitting';

        Test.startTest();

        registerStubs(new MonitorTransmittingStub());

        List<getStructuredData.promptResponse> results =
            getStructuredData.invoke(new List<getStructuredData.Request>{ req });

        Test.stopTest();

        System.assert(!results.isEmpty());
        System.assert(results[0].Structured_Data.contains('Telemetry_Data'));
    }

    /* =====================================================
       4️. TEST: SummarizePrimaryCareDoctor
       ===================================================== */
    @IsTest
    static void testSummarizePrimaryCareDoctor() {

        Account acc = createAccountWithData('Doctor Test');

        getStructuredData.Request req = new getStructuredData.Request();
        req.AccountId = acc.Id;
        req.RequestType = 'SummarizePrimaryCareDoctor';

        Test.startTest();

        registerStubs(new SummarizeDoctorStub());

        List<getStructuredData.promptResponse> results =
            getStructuredData.invoke(new List<getStructuredData.Request>{ req });

        Test.stopTest();

        System.assert(!results.isEmpty());
        System.assert(results[0].Structured_Data.contains('Telemetry_Data'));
        System.assert(results[0].Structured_Data.contains('Case_History_Data'));
    }

    /* =====================================================
       5️. TEST: Blank RequestType
       ===================================================== */
    @IsTest
    static void testBlankRequestType() {

        Account acc = createAccountWithData('Error Test');

        getStructuredData.Request req = new getStructuredData.Request();
        req.AccountId = acc.Id;
        req.RequestType = '';

        Test.startTest();

        List<getStructuredData.promptResponse> results =
            getStructuredData.invoke(new List<getStructuredData.Request>{ req });

        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    /* =====================================================
       	REGISTER ONLY DATA CLOUD STUBS
       ===================================================== */
    private static void registerStubs(SoqlStubProvider stub) {

        Test.createSoqlStub(ssot__Asset__dlm.SObjectType, stub);
        Test.createSoqlStub(ssot__Product__dlm.SObjectType, stub);
        Test.createSoqlStub(Entitlement_Home__dlm.SObjectType, stub);
        Test.createSoqlStub(pacemaker_iot_data__dlm.SObjectType, stub);
        Test.createSoqlStub(ssot__Case__dlm.SObjectType, stub);
    }

    /* =====================================================
       	STUB #1: Home Monitor
       ===================================================== */
    private class HomeMonitorStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(
            SObjectType sot, String query, Map<String, Object> bindVars) {

            if (sot == ssot__Asset__dlm.SObjectType) {
                return new List<SObject>{
                    Test.createStubQueryRow(sot, new Map<String,Object>{
                        'ssot__ProductId__c' => '01t000000000001AAA'
                    })
                };
            }

            if (sot == ssot__Product__dlm.SObjectType) {
                return new List<SObject>{
                    Test.createStubQueryRow(sot, new Map<String,Object>{
                        'ssot__Id__c' => '01t000000000001AAA',
                        'ssot__Name__c' => 'Home Monitor Device',
                        'Device_Type__c' => 'Type A',
                        'OS_Version__c' => 'v1.0',
                        'ssot__ProductCode__c' => 'HM100'
                    })
                };
            }

            return new List<SObject>();
        }
    }

    /* =====================================================
       	STUB #2: Warranty Coverage
       ===================================================== */
    private class WarrantyCoverageStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(
            SObjectType sot, String query, Map<String, Object> bindVars) {

            if (sot == ssot__Asset__dlm.SObjectType) {
                return new List<SObject>{
                    Test.createStubQueryRow(sot, new Map<String,Object>{
                        'ssot__Id__c' => 'a01000000000001AAA',
                        'ssot__ProductId__c' => '01t000000000002AAA'
                    })
                };
            }

            if (sot == ssot__Product__dlm.SObjectType) {
                return new List<SObject>{
                    Test.createStubQueryRow(sot, new Map<String,Object>{
                        'ssot__Id__c' => '01t000000000002AAA',
                        'ssot__Name__c' => 'Warranty Device'
                    })
                };
            }

            if (sot == Entitlement_Home__dlm.SObjectType) {
                return new List<SObject>{
                    Test.createStubQueryRow(sot, new Map<String,Object>{
                        'AssetId__c' => 'a01000000000001AAA',
                        'StartDate__c' => Date.today().addDays(-5),
                        'EndDate__c' => Date.today().addDays(10)
                    })
                };
            }

            return new List<SObject>();
        }
    }

    /* =====================================================
       	STUB #3: Monitor Transmitting
       ===================================================== */
    private class MonitorTransmittingStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(
            SObjectType sot, String query, Map<String, Object> bindVars) {

            if (sot == pacemaker_iot_data__dlm.SObjectType) {
                return new List<SObject>{
                    Test.createStubQueryRow(sot, new Map<String,Object>{
                        'Serial_Number__c' => 'SN-TEST-001',
                        'Battery_Status__c' => 'Good',
                        'Transmission_Timestamp__c' => Datetime.now()
                    })
                };
            }

            return new List<SObject>();
        }
    }

    /* =====================================================
       	STUB #4: Summarize Doctor
       ===================================================== */
    private class SummarizeDoctorStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(
            SObjectType sot, String query, Map<String, Object> bindVars) {

            if (sot == pacemaker_iot_data__dlm.SObjectType) {
                return new List<SObject>{
                    Test.createStubQueryRow(sot, new Map<String,Object>{
                        'Serial_Number__c' => 'SN-TEST-001',
                        'Transmission_Timestamp__c' => Datetime.now()
                    })
                };
            }

            if (sot == ssot__Case__dlm.SObjectType) {
                return new List<SObject>{
                    Test.createStubQueryRow(sot, new Map<String,Object>{
                        'ssot__Subject__c' => 'Chest Pain',
                        'ssot__CaseStatusId__c' => 'Open'
                    })
                };
            }

            return new List<SObject>();
        }
    }
}