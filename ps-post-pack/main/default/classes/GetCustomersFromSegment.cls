public with sharing class GetCustomersFromSegment 
{
    
     public static String getSessionIdFromVFPage()
     {
         if (Test.isRunningTest()) {
        return 'MY_SESSION_ID'; // Return dummy session ID in tests
    	}
        //String SessionId;
         PageReference visualforcePage = Page.EPSessionIdHelper;
         String content = visualforcePage.getContent().toString();
         Integer s = content.indexOf('Start_Of_Session_Id') + 'Start_Of_Session_Id'.length(),
             e = content.indexOf('End_Of_Session_Id');
         return content.substring(s, e);

    }
 
    @AuraEnabled(cacheable=true)
    public static String getContactSegmentStatus(ID id) {
        List<Contact> conList = [SELECT Id,Unified_Individual_Id__c FROM Contact where AccountId =: id Limit 1];
        String orgURL = System.URL.getOrgDomainUrl().toExternalForm();
        String  message = 'Device Stable';
        if(!conList.isEmpty()){
            try {
                Http http = new Http();
                HttpRequest req = new HttpRequest();
                req.setEndpoint(orgURL + '/services/data/v62.0/ssot/segments/Anomalous_Pacemaker_Battery/members');
                req.setMethod('GET');
                if(!Test.isRunningTest()){
                    req.setHeader('Authorization', 'Bearer ' + getSessionIdFromVFPage());
                }
                HttpResponse res = http.send(req);
                System.debug('Response Body : ' + res.getBody());

                String jsonString = res.getBody();
                if (res.getStatusCode() == 200) {
                    System.debug('StatusCode'+ res.getStatusCode());
                    Map<String, Object> jsonObj = (Map<String, Object>) JSON.deserializeUntyped(jsonString);

                    if (jsonObj.containsKey('data')) {
                        List<Object> dataList = (List<Object>) jsonObj.get('data');
                        for (Object itemObj : dataList) {
                            Map<String, Object> item = (Map<String, Object>) itemObj;
                            System.debug('Item: ' + item);

                            if (item.containsKey('id') && (String) item.get('id') != NULL) {
                                System.debug('## IndIds = '+(String) item.get('id'));
                                if((String) item.get('id') == conList[0].Unified_Individual_Id__c){
                                    
                                    message = 'Critical Device Outlier';
                                    break; 
                                }else{
                                    
                                    message = 'Device Stable';
                                    break;
                                }                            
                            }
                        }                    
                    } else {
                        message = 'Not Eligible for upgrade';
                    }
                } else {
                    System.debug('The JSON string is empty.');
                }
            } catch (Exception e) {
                System.debug('Exception: ' + e.getMessage());
            } 
        } 
        System.debug('## message = '+message);      
        return message; // Return the accountId
    }   
}