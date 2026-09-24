global with sharing class SchedulePromptInvoker {

    global class Input {
        @InvocableVariable(required=true label='Reference Date')
        global DateTime inputDate;
    }

    global class Output {
        @InvocableVariable(label='Prompt Response')
        global String promptResponse;
    }

    @InvocableMethod(
        label='Schedule Remote Device - Prompt Invoker'
        description='Calls the Schedule_Remote_Device prompt template and returns the model response'
        category='Prompt'
        callout=true
    )
    global static List<Output> invoke(List<Input> inputs) {

        List<Output> outputs = new List<Output>();

        if (inputs == null || inputs.isEmpty()) {
            return outputs;
        }

        for (Input i : inputs) {
            Output o = new Output();
            o.promptResponse = '';

            try {
                Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
                ConnectApi.WrappedValue dateWrapper = new ConnectApi.WrappedValue();
                dateWrapper.value = (i.inputDate != null ? String.valueOf(i.inputDate) : String.valueOf(DateTime.now()));
                inputParams.put('Input:Date', dateWrapper);

                ConnectApi.EinsteinPromptTemplateGenerationsInput req =
                    new ConnectApi.EinsteinPromptTemplateGenerationsInput();
                req.isPreview = false;
                req.inputParams = inputParams;
                req.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
                req.additionalConfig.applicationName = 'PromptBuilderPreview';

                ConnectApi.EinsteinPromptTemplateGenerationsRepresentation resp =
                    ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                        'Schedule_Remote_Device',
                        req
                    );

                if (resp != null
                    && resp.generations != null
                    && !resp.generations.isEmpty()
                    && resp.generations[0].text != null) {
                    o.promptResponse = resp.generations[0].text;
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'SchedulePromptInvoker error: ' + e.getMessage()
                    + '\n' + e.getStackTraceString());
                o.promptResponse = 'Unable to suggest appointment dates right now. Please try again.';
            }

            outputs.add(o);
        }

        return outputs;
    }
}
