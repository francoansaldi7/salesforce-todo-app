// Unit tests for TaskController. Each method in the controller has at least one
// positive test and, where applicable, a negative / edge-case test.
@IsTest
private class TaskControllerTest {

    /**
     * Shared test data created once per test class run.
     * @TestSetup runs before every test method automatically.
     * Using LIMIT avoids governor issues if other tests also insert tasks.
     */
    @TestSetup
    static void setupTestData() {
        // Two pending + one completed task owned by the running (test) user
        List<To_Do_Task__c> tasks = new List<To_Do_Task__c>{
            new To_Do_Task__c(Name = 'Pending Task 1', Completed__c = false, Status__c = 'Pending'),
            new To_Do_Task__c(Name = 'Pending Task 2', Completed__c = false, Status__c = 'Pending'),
            new To_Do_Task__c(
                Name = 'Completed Task',
                Completed__c = true,
                Status__c = 'Completed',
                Completed_Date__c = Date.today() // today ensures it passes WEEK and MONTH filters
            )
        };
        insert tasks;
    }

    /** Creates a second user (System Administrator, so profile-level access is never the
     *  reason a cross-user call fails) with the same To_Do_App_Access permission set a
     *  real user would have. Granting the same field-level access isolates these tests
     *  to exactly what they claim to test — the OwnerId scoping — rather than letting an
     *  unrelated FLS gap on the test user accidentally produce a passing (but wrong-reason)
     *  result. */
    private static User createOtherUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String uniqueKey = String.valueOf(DateTime.now().getTime());
        User u = new User(
            FirstName = 'Other',
            LastName = 'TestUser',
            Email = 'other.testuser@example.com',
            Username = 'other.testuser' + uniqueKey + '@example.com',
            Alias = 'othusr',
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = p.Id
        );
        // Isolated in its own System.runAs to avoid MIXED_DML_OPERATION — inserting a
        // setup object (User, PermissionSetAssignment) in the same transaction as a
        // prior non-setup DML (e.g. a To_Do_Task__c update earlier in the calling test)
        // is not allowed otherwise.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;

            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'To_Do_App_Access' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }

        return u;
    }

    // Inserts extra pending tasks named 'Bulk Pending N' (1-based) so pagination tests
    // have more than one page's worth of data (page size is 15) without hardcoding it
    // in every test.
    private static void insertBulkPendingTasks(Integer count) {
        List<To_Do_Task__c> tasks = new List<To_Do_Task__c>();
        for (Integer i = 1; i <= count; i++) {
            tasks.add(new To_Do_Task__c(
                Name = 'Bulk Pending ' + i,
                Completed__c = false,
                Status__c = 'Pending'
            ));
        }
        insert tasks;
    }

    // ─── getPendingTasks ──────────────────────────────────────────────────────

    /** Verifies that only non-completed tasks owned by the current user are returned. */
    @IsTest
    static void testGetPendingTasks_returnsOnlyPendingForCurrentUser() {
        Test.startTest();
        TaskController.PagedTasks page = TaskController.getPendingTasks(null, 1, 0);
        Test.stopTest();

        Assert.isNotNull(page.records);
        Assert.areEqual(2, page.records.size()); // exactly the 2 pending tasks from setup
        Assert.areEqual(2, page.totalCount);
        for (To_Do_Task__c t : page.records) {
            Assert.isFalse(t.Completed__c); // no completed tasks should slip through
        }
    }

    /** Pending tasks with an explicit Sort_Order__c must come back in that order,
     *  ahead of tasks that have never been manually ordered. */
    @IsTest
    static void testGetPendingTasks_ordersBySortOrderThenCreatedDate() {
        To_Do_Task__c task1 = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];
        To_Do_Task__c task2 = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 2' LIMIT 1];

        // Put Task 2 ahead of Task 1 by giving it a lower Sort_Order__c
        update new List<To_Do_Task__c>{
            new To_Do_Task__c(Id = task1.Id, Sort_Order__c = 1),
            new To_Do_Task__c(Id = task2.Id, Sort_Order__c = 0)
        };

        Test.startTest();
        List<To_Do_Task__c> records = TaskController.getPendingTasks(null, 1, 0).records;
        Test.stopTest();

        Assert.areEqual('Pending Task 2', records[0].Name);
        Assert.areEqual('Pending Task 1', records[1].Name);
    }

    /** A task with no manual Sort_Order__c (i.e. never dragged — including a brand new
     *  task) must appear ahead of any task that has been manually sorted, so newly
     *  created tasks land at the top of the list rather than the bottom. */
    @IsTest
    static void testGetPendingTasks_unsortedTasksAppearBeforeManuallySortedOnes() {
        To_Do_Task__c sortedTask = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];
        update new To_Do_Task__c(Id = sortedTask.Id, Sort_Order__c = 0);
        // 'Pending Task 2' is left with no Sort_Order__c, as a newly created task would be.

        Test.startTest();
        List<To_Do_Task__c> records = TaskController.getPendingTasks(null, 1, 0).records;
        Test.stopTest();

        Assert.areEqual(
            'Pending Task 2', records[0].Name,
            'The unsorted task must appear first, ahead of the manually sorted one'
        );
        Assert.areEqual('Pending Task 1', records[1].Name);
    }

    /** With more than one page of pending tasks, page 1 must hold exactly 15 records
     *  and totalCount must reflect every pending task, not just the current page. */
    @IsTest
    static void testGetPendingTasks_page1_returnsFirstFifteenOfTotal() {
        insertBulkPendingTasks(20); // + the 2 from setup = 22 total pending

        Test.startTest();
        TaskController.PagedTasks page = TaskController.getPendingTasks(null, 1, 0);
        Test.stopTest();

        Assert.areEqual(15, page.records.size(), 'Page 1 must hold exactly one page size worth of records');
        Assert.areEqual(22, page.totalCount, 'totalCount must reflect every pending task, not just this page');
    }

    /** Page 2 must hold the remainder of the records not shown on page 1. */
    @IsTest
    static void testGetPendingTasks_page2_returnsRemainder() {
        insertBulkPendingTasks(20); // + the 2 from setup = 22 total pending

        Test.startTest();
        TaskController.PagedTasks page = TaskController.getPendingTasks(null, 2, 0);
        Test.stopTest();

        Assert.areEqual(7, page.records.size(), '22 total - 15 on page 1 = 7 remaining on page 2');
        Assert.areEqual(22, page.totalCount);
    }

    /** searchTerm must filter pending tasks by name (case-insensitive substring match). */
    @IsTest
    static void testGetPendingTasks_searchTerm_filtersByName() {
        Test.startTest();
        TaskController.PagedTasks page = TaskController.getPendingTasks('pending task 1', 1, 0);
        Test.stopTest();

        Assert.areEqual(1, page.totalCount);
        Assert.areEqual('Pending Task 1', page.records[0].Name);
    }

    /** A blank searchTerm must behave exactly like no search — every task matches. */
    @IsTest
    static void testGetPendingTasks_blankSearchTerm_returnsEverything() {
        Test.startTest();
        TaskController.PagedTasks page = TaskController.getPendingTasks('', 1, 0);
        Test.stopTest();

        Assert.areEqual(2, page.totalCount);
    }

    // ─── getCompletedTasks ────────────────────────────────────────────────────

    /** Empty string filter → "All" — should return the one completed task from setup. */
    @IsTest
    static void testGetCompletedTasks_allFilter_returnsAllCompleted() {
        Test.startTest();
        TaskController.PagedTasks page = TaskController.getCompletedTasks('', null, 1, 0);
        Test.stopTest();

        Assert.areEqual(1, page.records.size());
        Assert.areEqual('Completed Task', page.records[0].Name);
    }

    /** WEEK filter — setup task was completed today, so it must be included. */
    @IsTest
    static void testGetCompletedTasks_weekFilter_includesTaskCompletedToday() {
        Test.startTest();
        TaskController.PagedTasks page = TaskController.getCompletedTasks('WEEK', null, 1, 0);
        Test.stopTest();

        Assert.areEqual(1, page.records.size());
    }

    /** MONTH filter — same logic as WEEK; today's task must appear. */
    @IsTest
    static void testGetCompletedTasks_monthFilter_includesTaskCompletedToday() {
        Test.startTest();
        TaskController.PagedTasks page = TaskController.getCompletedTasks('MONTH', null, 1, 0);
        Test.stopTest();

        Assert.areEqual(1, page.records.size());
    }

    /** Any unrecognised filter value falls through to the "all" else branch. */
    @IsTest
    static void testGetCompletedTasks_unknownFilter_returnsAll() {
        Test.startTest();
        TaskController.PagedTasks page = TaskController.getCompletedTasks('UNKNOWN', null, 1, 0);
        Test.stopTest();

        Assert.areEqual(1, page.records.size());
    }

    /** Inserts a task completed 2 months ago and confirms the WEEK filter excludes it. */
    @IsTest
    static void testGetCompletedTasks_weekFilter_excludesOldTask() {
        To_Do_Task__c oldTask = new To_Do_Task__c(
            Name = 'Old Completed Task',
            Completed__c = true,
            Status__c = 'Completed',
            Completed_Date__c = Date.today().addMonths(-2) // outside WEEK and MONTH windows
        );
        insert oldTask;

        Test.startTest();
        TaskController.PagedTasks page = TaskController.getCompletedTasks('WEEK', null, 1, 0);
        Test.stopTest();

        // Only the task from @TestSetup (completed today) should remain
        Assert.areEqual(1, page.records.size(), 'Only this week\'s task should be returned');
    }

    /** searchTerm must filter completed tasks by name too. */
    @IsTest
    static void testGetCompletedTasks_searchTerm_filtersByName() {
        insert new To_Do_Task__c(
            Name = 'Another Completed Thing',
            Completed__c = true,
            Status__c = 'Completed',
            Completed_Date__c = Date.today()
        );

        Test.startTest();
        TaskController.PagedTasks page = TaskController.getCompletedTasks('', 'Another', 1, 0);
        Test.stopTest();

        Assert.areEqual(1, page.totalCount);
        Assert.areEqual('Another Completed Thing', page.records[0].Name);
    }

    // ─── toggleTaskStatus ─────────────────────────────────────────────────────

    /** Ticking a pending task must flip Completed__c to true and set Status to Completed. */
    @IsTest
    static void testToggleTaskStatus_pendingToComplete() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];

        Test.startTest();
        TaskController.toggleTaskStatus(task.Id);
        Test.stopTest();

        To_Do_Task__c updated = [SELECT Completed__c, Status__c FROM To_Do_Task__c WHERE Id = :task.Id];
        Assert.isTrue(updated.Completed__c);
        Assert.areEqual('Completed', updated.Status__c);
    }

    /** Un-ticking a completed task must flip it back to Pending and clear Completed_Date__c. */
    @IsTest
    static void testToggleTaskStatus_completeToPending() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Completed Task' LIMIT 1];

        Test.startTest();
        TaskController.toggleTaskStatus(task.Id);
        Test.stopTest();

        To_Do_Task__c updated = [SELECT Completed__c, Status__c, Completed_Date__c FROM To_Do_Task__c WHERE Id = :task.Id];
        Assert.isFalse(updated.Completed__c);
        Assert.areEqual('Pending', updated.Status__c);
        Assert.isNull(updated.Completed_Date__c); // date must be cleared when un-completing
    }

    /** Completing a Daily-recurring task must schedule its next occurrence for tomorrow. */
    @IsTest
    static void testToggleTaskStatus_recurringDailyTask_schedulesNextOccurrence() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];
        update new To_Do_Task__c(Id = task.Id, Recurrence__c = 'Daily');

        Test.startTest();
        TaskController.toggleTaskStatus(task.Id);
        Test.stopTest();

        To_Do_Task__c updated = [SELECT Next_Occurrence_Date__c FROM To_Do_Task__c WHERE Id = :task.Id];
        Assert.areEqual(Date.today().addDays(1), updated.Next_Occurrence_Date__c);
    }

    /** Un-completing a task must cancel any pending recurrence it had scheduled. */
    @IsTest
    static void testToggleTaskStatus_completeToPending_clearsNextOccurrence() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Completed Task' LIMIT 1];
        update new To_Do_Task__c(
            Id = task.Id,
            Recurrence__c = 'Weekly',
            Next_Occurrence_Date__c = Date.today().addDays(7)
        );

        Test.startTest();
        TaskController.toggleTaskStatus(task.Id);
        Test.stopTest();

        To_Do_Task__c updated = [SELECT Next_Occurrence_Date__c FROM To_Do_Task__c WHERE Id = :task.Id];
        Assert.isNull(updated.Next_Occurrence_Date__c);
    }

    // ─── Cross-user access (IDOR) protection ────────────────────────────────────

    /** A different user must not be able to toggle a task they don't own. */
    @IsTest
    static void testToggleTaskStatus_otherUsersTask_throwsException() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];
        User otherUser = createOtherUser();

        Boolean exceptionThrown = false;
        System.runAs(otherUser) {
            try {
                TaskController.toggleTaskStatus(task.Id);
            } catch (Exception e) {
                exceptionThrown = true;
            }
        }

        Assert.isTrue(exceptionThrown, 'A user must not be able to toggle another user\'s task');
    }

    /** A different user must not be able to delete a task they don't own. */
    @IsTest
    static void testDeleteTask_otherUsersTask_throwsException() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];
        User otherUser = createOtherUser();

        Boolean exceptionThrown = false;
        System.runAs(otherUser) {
            try {
                TaskController.deleteTask(task.Id);
            } catch (Exception e) {
                exceptionThrown = true;
            }
        }

        Assert.isTrue(exceptionThrown, 'A user must not be able to delete another user\'s task');

        // Confirm the record still exists — the delete must not have gone through.
        List<To_Do_Task__c> remaining = [SELECT Id FROM To_Do_Task__c WHERE Id = :task.Id];
        Assert.areEqual(1, remaining.size(), 'The task must not have been deleted');
    }

    /** A different user must not be able to edit a task they don't own. */
    @IsTest
    static void testUpdateTask_otherUsersTask_throwsException() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];
        User otherUser = createOtherUser();

        Boolean exceptionThrown = false;
        System.runAs(otherUser) {
            try {
                TaskController.updateTask(task.Id, 'Hijacked Name', 'High', 'Work', 'hijacked', 'None');
            } catch (Exception e) {
                exceptionThrown = true;
            }
        }

        Assert.isTrue(exceptionThrown, 'A user must not be able to edit another user\'s task');

        // Confirm nothing changed.
        To_Do_Task__c unchanged = [SELECT Name FROM To_Do_Task__c WHERE Id = :task.Id];
        Assert.areEqual('Pending Task 1', unchanged.Name, 'The task must not have changed');
    }

    /** A different user's reorder call must not be able to touch another user's task —
     *  its Sort_Order__c must be silently skipped rather than applied. */
    @IsTest
    static void testReorderTasks_otherUsersTaskId_isIgnored() {
        To_Do_Task__c task = [SELECT Id, Sort_Order__c FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];
        User otherUser = createOtherUser();

        System.runAs(otherUser) {
            TaskController.reorderTasks(new List<Id>{ task.Id }, 0);
        }

        To_Do_Task__c unchanged = [SELECT Sort_Order__c FROM To_Do_Task__c WHERE Id = :task.Id];
        Assert.isNull(unchanged.Sort_Order__c, 'Another user\'s reorder call must not set Sort_Order__c');
    }

    // ─── createTask ───────────────────────────────────────────────────────────

    /** New tasks must be created with Completed__c = false and Status = Pending. */
    @IsTest
    static void testCreateTask_insertsWithCorrectDefaults() {
        Test.startTest();
        TaskController.createTask('Brand New Task');
        Test.stopTest();

        List<To_Do_Task__c> tasks = [
            SELECT Name, Completed__c, Status__c, Priority__c, Recurrence__c
            FROM To_Do_Task__c
            WHERE Name = 'Brand New Task'
        ];
        Assert.areEqual(1, tasks.size());
        Assert.isFalse(tasks[0].Completed__c);
        Assert.areEqual('Pending', tasks[0].Status__c);
        Assert.areEqual('Medium', tasks[0].Priority__c);
        Assert.areEqual('None', tasks[0].Recurrence__c);
    }

    /** createTask with a blank name must throw AuraHandledException. */
    @IsTest
    static void testCreateTask_blankName_throwsException() {
        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            TaskController.createTask('   ');
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        Assert.isTrue(exceptionThrown, 'Blank task name must throw an exception');
    }

    // ─── deleteTask ───────────────────────────────────────────────────────────

    /** The record must no longer exist in the database after deleteTask is called. */
    @IsTest
    static void testDeleteTask_removesRecord() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];

        Test.startTest();
        TaskController.deleteTask(task.Id);
        Test.stopTest();

        List<To_Do_Task__c> remaining = [SELECT Id FROM To_Do_Task__c WHERE Id = :task.Id];
        Assert.areEqual(0, remaining.size()); // list must be empty — record deleted
    }

    /** deleteTask with an already-deleted Id must throw, not silently fail. */
    @IsTest
    static void testDeleteTask_alreadyDeleted_throwsException() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];
        delete task;

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            TaskController.deleteTask(task.Id);
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        Assert.isTrue(exceptionThrown, 'Deleting a non-existent record must throw');
    }

    // ─── updateTask ───────────────────────────────────────────────────────────

    /** All editable fields must be saved together. */
    @IsTest
    static void testUpdateTask_updatesAllFields() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];

        Test.startTest();
        TaskController.updateTask(task.Id, 'Updated Name', 'High', 'Work', 'Some notes', 'Weekly');
        Test.stopTest();

        To_Do_Task__c updated = [
            SELECT Name, Priority__c, Category__c, Notes__c, Recurrence__c
            FROM To_Do_Task__c
            WHERE Id = :task.Id
        ];
        Assert.areEqual('Updated Name', updated.Name);
        Assert.areEqual('High', updated.Priority__c);
        Assert.areEqual('Work', updated.Category__c);
        Assert.areEqual('Some notes', updated.Notes__c);
        Assert.areEqual('Weekly', updated.Recurrence__c);
    }

    /** Passing an empty name must throw an AuraHandledException. */
    @IsTest
    static void testUpdateTask_emptyName_throwsException() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            TaskController.updateTask(task.Id, '', 'Medium', null, null, 'None');
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        Assert.isTrue(exceptionThrown);
    }

    /** Passing whitespace-only must also throw — String.isBlank() treats it the same as empty. */
    @IsTest
    static void testUpdateTask_whitespaceOnlyName_throwsException() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            TaskController.updateTask(task.Id, '   ', 'Medium', null, null, 'None');
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        Assert.isTrue(exceptionThrown);
    }

    // ─── reorderTasks ─────────────────────────────────────────────────────────

    /** Reordering with no start index (page 1) must assign Sort_Order__c sequentially
     *  from 0, matching the given Id order. */
    @IsTest
    static void testReorderTasks_setsSequentialSortOrder() {
        To_Do_Task__c task1 = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];
        To_Do_Task__c task2 = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 2' LIMIT 1];

        Test.startTest();
        TaskController.reorderTasks(new List<Id>{ task2.Id, task1.Id }, 0);
        Test.stopTest();

        Map<Id, To_Do_Task__c> updated = new Map<Id, To_Do_Task__c>(
            [SELECT Id, Sort_Order__c FROM To_Do_Task__c WHERE Id IN :new List<Id>{ task1.Id, task2.Id }]
        );
        Assert.areEqual(0, updated.get(task2.Id).Sort_Order__c);
        Assert.areEqual(1, updated.get(task1.Id).Sort_Order__c);
    }

    /** Reordering a later page must offset Sort_Order__c by the given startIndex, so it
     *  doesn't collide with an earlier page's ordering (e.g. page 2 with a 15-per-page
     *  size starts at 15). */
    @IsTest
    static void testReorderTasks_withStartIndex_offsetsSortOrder() {
        To_Do_Task__c task1 = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];
        To_Do_Task__c task2 = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 2' LIMIT 1];

        Test.startTest();
        TaskController.reorderTasks(new List<Id>{ task2.Id, task1.Id }, 15);
        Test.stopTest();

        Map<Id, To_Do_Task__c> updated = new Map<Id, To_Do_Task__c>(
            [SELECT Id, Sort_Order__c FROM To_Do_Task__c WHERE Id IN :new List<Id>{ task1.Id, task2.Id }]
        );
        Assert.areEqual(15, updated.get(task2.Id).Sort_Order__c);
        Assert.areEqual(16, updated.get(task1.Id).Sort_Order__c);
    }

    // ─── markAllTasksComplete ─────────────────────────────────────────────────

    /** Every pending task owned by the user must become Completed. */
    @IsTest
    static void testMarkAllTasksComplete_completesAllPending() {
        Test.startTest();
        TaskController.markAllTasksComplete();
        Test.stopTest();

        List<To_Do_Task__c> stillPending = [SELECT Id FROM To_Do_Task__c WHERE Completed__c = false];
        Assert.areEqual(0, stillPending.size(), 'No pending tasks should remain');
    }

    /** A recurring task swept up by "mark all complete" must also get its next occurrence scheduled. */
    @IsTest
    static void testMarkAllTasksComplete_schedulesRecurrence() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Pending Task 1' LIMIT 1];
        update new To_Do_Task__c(Id = task.Id, Recurrence__c = 'Monthly');

        Test.startTest();
        TaskController.markAllTasksComplete();
        Test.stopTest();

        To_Do_Task__c updated = [SELECT Next_Occurrence_Date__c FROM To_Do_Task__c WHERE Id = :task.Id];
        Assert.areEqual(Date.today().addMonths(1), updated.Next_Occurrence_Date__c);
    }

    // ─── clearCompletedTasks / restoreArchivedTask ───────────────────────────────

    /** Completed tasks must be archived (hidden), not deleted; pending tasks untouched. */
    @IsTest
    static void testClearCompletedTasks_archivesRatherThanDeletes() {
        Test.startTest();
        TaskController.clearCompletedTasks();
        Test.stopTest();

        Assert.areEqual(
            1, [SELECT COUNT() FROM To_Do_Task__c WHERE Status__c = 'Completed'],
            'The completed task must still exist'
        );
        Assert.areEqual(
            1, [SELECT COUNT() FROM To_Do_Task__c WHERE Status__c = 'Completed' AND Archived__c = true],
            'The completed task must now be archived'
        );
        Assert.areEqual(2, [SELECT COUNT() FROM To_Do_Task__c WHERE Status__c = 'Pending']);
    }

    /** Archived tasks must no longer appear in the normal (non-archived) completed views. */
    @IsTest
    static void testGetCompletedTasks_excludesArchivedFromNormalViews() {
        TaskController.clearCompletedTasks();

        Test.startTest();
        TaskController.PagedTasks page = TaskController.getCompletedTasks('', null, 1, 0);
        Test.stopTest();

        Assert.areEqual(0, page.records.size(), 'Archived tasks must not appear in the normal completed list');
    }

    /** The ARCHIVED filter must return exactly the tasks "Clear Completed" archived. */
    @IsTest
    static void testGetCompletedTasks_archivedFilter_returnsOnlyArchived() {
        TaskController.clearCompletedTasks();

        Test.startTest();
        TaskController.PagedTasks page = TaskController.getCompletedTasks('ARCHIVED', null, 1, 0);
        Test.stopTest();

        Assert.areEqual(1, page.records.size());
        Assert.areEqual('Completed Task', page.records[0].Name);
    }

    /** Restoring an archived task must bring it back into the normal completed view. */
    @IsTest
    static void testRestoreArchivedTask_bringsTaskBackToNormalView() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Completed Task' LIMIT 1];
        TaskController.clearCompletedTasks();

        Test.startTest();
        TaskController.restoreArchivedTask(task.Id);
        Test.stopTest();

        TaskController.PagedTasks normalView = TaskController.getCompletedTasks('', null, 1, 0);
        Assert.areEqual(1, normalView.records.size(), 'The restored task must appear in the normal view again');

        TaskController.PagedTasks archivedView = TaskController.getCompletedTasks('ARCHIVED', null, 1, 0);
        Assert.areEqual(0, archivedView.records.size(), 'The restored task must no longer appear in the Archived view');
    }

    /** A different user must not be able to restore a task they don't own. */
    @IsTest
    static void testRestoreArchivedTask_otherUsersTask_throwsException() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Completed Task' LIMIT 1];
        TaskController.clearCompletedTasks();
        User otherUser = createOtherUser();

        Boolean exceptionThrown = false;
        System.runAs(otherUser) {
            try {
                TaskController.restoreArchivedTask(task.Id);
            } catch (Exception e) {
                exceptionThrown = true;
            }
        }

        Assert.isTrue(exceptionThrown, 'A user must not be able to restore another user\'s archived task');
    }

    /** Restoring all must bring back every archived task the user owns, in one call. */
    @IsTest
    static void testRestoreAllArchivedTasks_restoresEveryArchivedTask() {
        insert new To_Do_Task__c(
            Name = 'Second Completed Task',
            Completed__c = true,
            Status__c = 'Completed',
            Completed_Date__c = Date.today()
        );
        TaskController.clearCompletedTasks();

        Test.startTest();
        TaskController.restoreAllArchivedTasks();
        Test.stopTest();

        TaskController.PagedTasks normalView = TaskController.getCompletedTasks('', null, 1, 0);
        Assert.areEqual(2, normalView.records.size(), 'Both tasks must be back in the normal completed view');

        TaskController.PagedTasks archivedView = TaskController.getCompletedTasks('ARCHIVED', null, 1, 0);
        Assert.areEqual(0, archivedView.records.size(), 'Nothing should remain archived');
    }

    /** Restoring all must only touch the running user's own archived tasks. */
    @IsTest
    static void testRestoreAllArchivedTasks_doesNotAffectOtherUsersTasks() {
        TaskController.clearCompletedTasks();
        User otherUser = createOtherUser();

        System.runAs(otherUser) {
            TaskController.restoreAllArchivedTasks();
        }

        Assert.areEqual(
            1, [SELECT COUNT() FROM To_Do_Task__c WHERE Status__c = 'Completed' AND Archived__c = true],
            'The original owner\'s archived task must remain archived'
        );
    }

    // ─── materializeDueRecurrences ────────────────────────────────────────────

    /** A completed recurring task whose Next_Occurrence_Date__c has arrived must spawn
     *  a new pending task, and must not be able to spawn a second one afterwards. */
    @IsTest
    static void testMaterializeDueRecurrences_createsNextOccurrenceWhenDue() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Completed Task' LIMIT 1];
        update new To_Do_Task__c(
            Id = task.Id,
            Recurrence__c = 'Daily',
            Next_Occurrence_Date__c = Date.today() // due today
        );

        Test.startTest();
        TaskController.materializeDueRecurrences();
        Test.stopTest();

        List<To_Do_Task__c> newOccurrences = [
            SELECT Id FROM To_Do_Task__c
            WHERE Name = 'Completed Task' AND Status__c = 'Pending'
        ];
        Assert.areEqual(1, newOccurrences.size(), 'A new pending occurrence must have been created');

        To_Do_Task__c original = [SELECT Next_Occurrence_Date__c FROM To_Do_Task__c WHERE Id = :task.Id];
        Assert.isNull(original.Next_Occurrence_Date__c, 'The original must not spawn duplicates on a second run');
    }

    /** A recurring task whose next occurrence is still in the future must not spawn early. */
    @IsTest
    static void testMaterializeDueRecurrences_doesNothingBeforeDue() {
        To_Do_Task__c task = [SELECT Id FROM To_Do_Task__c WHERE Name = 'Completed Task' LIMIT 1];
        update new To_Do_Task__c(
            Id = task.Id,
            Recurrence__c = 'Weekly',
            Next_Occurrence_Date__c = Date.today().addDays(3) // not due yet
        );

        Test.startTest();
        TaskController.materializeDueRecurrences();
        Test.stopTest();

        List<To_Do_Task__c> newOccurrences = [
            SELECT Id FROM To_Do_Task__c
            WHERE Name = 'Completed Task' AND Status__c = 'Pending'
        ];
        Assert.areEqual(0, newOccurrences.size(), 'No occurrence should be created before its scheduled date');
    }
}
