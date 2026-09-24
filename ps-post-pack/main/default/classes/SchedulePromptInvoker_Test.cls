@IsTest
private class SchedulePromptInvoker_Test {

    @IsTest
    static void testEmptyInputList() {
        Test.startTest();
        List<SchedulePromptInvoker.Output> result =
            SchedulePromptInvoker.invoke(new List<SchedulePromptInvoker.Input>());
        Test.stopTest();

        System.assertEquals(0, result.size(), 'Empty input should return empty output');
    }

    @IsTest
    static void testNullInputList() {
        Test.startTest();
        List<SchedulePromptInvoker.Output> result =
            SchedulePromptInvoker.invoke(null);
        Test.stopTest();

        System.assertEquals(0, result.size(), 'Null input should return empty output');
    }

    @IsTest
    static void testSingleInputTriggersFallbackOrRealCall() {
        SchedulePromptInvoker.Input input = new SchedulePromptInvoker.Input();
        input.inputDate = DateTime.now();

        Test.startTest();
        List<SchedulePromptInvoker.Output> result =
            SchedulePromptInvoker.invoke(new List<SchedulePromptInvoker.Input>{input});
        Test.stopTest();

        System.assertEquals(1, result.size(), 'Should return one Output per Input');
        System.assertNotEquals(null, result[0].promptResponse,
            'Output.promptResponse must be non-null');
    }

    @IsTest
    static void testMultipleInputsBatched() {
        SchedulePromptInvoker.Input i1 = new SchedulePromptInvoker.Input();
        i1.inputDate = DateTime.now();
        SchedulePromptInvoker.Input i2 = new SchedulePromptInvoker.Input();
        i2.inputDate = DateTime.now().addDays(7);

        Test.startTest();
        List<SchedulePromptInvoker.Output> result =
            SchedulePromptInvoker.invoke(new List<SchedulePromptInvoker.Input>{i1, i2});
        Test.stopTest();

        System.assertEquals(2, result.size(), 'Should return one Output per Input');
    }
}
