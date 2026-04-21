@IsTest(seeAllData=false)
private class GetCustomersFromSegment_Test {

    // Simple reusable HTTP mock
    private class SimpleHttpMock implements HttpCalloutMock {
        private Integer code;
        private String body;

        SimpleHttpMock(Integer code, String body) {
            this.code = code;
            this.body = body;
        }

        public HttpResponse respond(HTTPRequest req) {

            System.assertEquals('GET', req.getMethod());
            System.assert(
                req.getEndpoint().endsWith('/services/data/v62.0/ssot/segments/Anomalous_Pacemaker_Battery/members'),
                'Unexpected endpoint: ' + req.getEndpoint()
            );

            HttpResponse res = new HttpResponse();
            res.setStatusCode(code);
            res.setBody(body);
            return res;
        }
    }

    // Helper records
    private static Account makeAccount() {
        Account a = new Account(Name = 'Acme');
        insert a;
        return a;
    }

    private static Contact makeContact(Id accId, String uid) {
        Contact c = new Contact(
            LastName = 'Tester',
            AccountId = accId,
            Unified_Individual_Id__c = uid
        );
        insert c;
        return c;
    }

    // ========== TESTS ==========

    @IsTest
    static void test_getSessionIdFromVFPage_returnsDummyInTests() {
        Test.startTest();
        String sid = GetCustomersFromSegment.getSessionIdFromVFPage();
        Test.stopTest();
        System.assertEquals('MY_SESSION_ID', sid);
    }

    @IsTest
    static void test_getContactSegmentStatus_MatchingId() {
        Account a = makeAccount();
        Contact c = makeContact(a.Id, 'IND123');

        String body = '{"data":[{"id":"IND123"}]}';
        Test.setMock(HttpCalloutMock.class, new SimpleHttpMock(200, body));

        Test.startTest();
        String result = GetCustomersFromSegment.getContactSegmentStatus(a.Id);
        Test.stopTest();

        System.assertEquals('Critical Device Outlier', result);
    }

    @IsTest
    static void test_getContactSegmentStatus_NotMatchingId() {
        Account a = makeAccount();
        Contact c = makeContact(a.Id, 'IND123');

        String body = '{"data":[{"id":"OTHER"}]}';
        Test.setMock(HttpCalloutMock.class, new SimpleHttpMock(200, body));

        Test.startTest();
        String result = GetCustomersFromSegment.getContactSegmentStatus(a.Id);
        Test.stopTest();

        System.assertEquals('Device Stable', result);
    }

    @IsTest
    static void test_getContactSegmentStatus_NoDataKey() {
        Account a = makeAccount();
        Contact c = makeContact(a.Id, 'IND123');

        String body = '{}';
        Test.setMock(HttpCalloutMock.class, new SimpleHttpMock(200, body));

        Test.startTest();
        String result = GetCustomersFromSegment.getContactSegmentStatus(a.Id);
        Test.stopTest();

        System.assertEquals('Not Eligible for upgrade', result);
    }

    @IsTest
    static void test_getContactSegmentStatus_Non200Response() {
        Account a = makeAccount();
        Contact c = makeContact(a.Id, 'IND123');

        String body = '{"error":"Fail"}';
        Test.setMock(HttpCalloutMock.class, new SimpleHttpMock(500, body));

        Test.startTest();
        String result = GetCustomersFromSegment.getContactSegmentStatus(a.Id);
        Test.stopTest();

        // Apex code defaults to 'Device Stable' unless overridden
        System.assertEquals('Device Stable', result);
    }

    @IsTest
    static void test_getContactSegmentStatus_BadJson() {
        Account a = makeAccount();
        Contact c = makeContact(a.Id, 'IND123');

        String body = 'not-json';
        Test.setMock(HttpCalloutMock.class, new SimpleHttpMock(200, body));

        Test.startTest();
        String result = GetCustomersFromSegment.getContactSegmentStatus(a.Id);
        Test.stopTest();

        // Exception handled → default message remains
        System.assertEquals('Device Stable', result);
    }

    @IsTest
    static void test_getContactSegmentStatus_NoContact() {
        Account a = makeAccount(); // No contact created

        Test.startTest();
        String result = GetCustomersFromSegment.getContactSegmentStatus(a.Id);
        Test.stopTest();

        // No contact → default "Device Stable"
        System.assertEquals('Device Stable', result);
    }
}