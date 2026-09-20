import { createElement } from 'lwc';
import TodoApp from 'c/todoApp';
import { getRecord } from 'lightning/uiRecordApi';

function flushPromises() {
    return new Promise(resolve => setTimeout(resolve, 0));
}

describe('c-todo-app', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('defaults to the Pending tab active on mobile', () => {
        const element = createElement('c-todo-app', { is: TodoApp });
        document.body.appendChild(element);

        const pendingTab = element.shadowRoot.querySelector('[data-tab="pending"]');
        const completedTab = element.shadowRoot.querySelector('[data-tab="completed"]');

        expect(pendingTab.className).toContain('mobile-tab--active');
        expect(completedTab.className).not.toContain('mobile-tab--active');
    });

    it('switches the active mobile tab when the Completed tab is clicked', async () => {
        const element = createElement('c-todo-app', { is: TodoApp });
        document.body.appendChild(element);

        const completedTab = element.shadowRoot.querySelector('[data-tab="completed"]');
        completedTab.click();
        await flushPromises();

        const pendingTab = element.shadowRoot.querySelector('[data-tab="pending"]');
        expect(completedTab.className).toContain('mobile-tab--active');
        expect(pendingTab.className).not.toContain('mobile-tab--active');
    });

    it('shows live counts reported by the child lists on the mobile tab labels', async () => {
        const element = createElement('c-todo-app', { is: TodoApp });
        document.body.appendChild(element);
        await flushPromises();

        const pendingList = element.shadowRoot.querySelector('c-todo-pending-list');
        const completedList = element.shadowRoot.querySelector('c-todo-completed-list');

        pendingList.dispatchEvent(new CustomEvent('pendingcountchange', { detail: { count: 3 } }));
        completedList.dispatchEvent(new CustomEvent('completedcountchange', { detail: { count: 7 } }));
        await flushPromises();

        const pendingTab = element.shadowRoot.querySelector('[data-tab="pending"]');
        const completedTab = element.shadowRoot.querySelector('[data-tab="completed"]');
        expect(pendingTab.textContent.trim()).toBe('Pending (3)');
        expect(completedTab.textContent.trim()).toBe('Completed (7)');
    });

    it('falls back to "Legend" in the greeting when the user has no first name yet', async () => {
        const element = createElement('c-todo-app', { is: TodoApp });
        document.body.appendChild(element);
        await flushPromises();

        const greeting = element.shadowRoot.querySelector('.greeting-banner__text');
        expect(greeting.textContent).toContain('Legend');
    });

    it('greets the user by their first name once the record wire emits data', async () => {
        const element = createElement('c-todo-app', { is: TodoApp });
        document.body.appendChild(element);

        getRecord.emit({ fields: { FirstName: { value: 'Franco' } } });
        await flushPromises();

        const greeting = element.shadowRoot.querySelector('.greeting-banner__text');
        expect(greeting.textContent).toContain('Franco');
    });

    it('refreshes both child lists when either one fires refreshlists', async () => {
        const element = createElement('c-todo-app', { is: TodoApp });
        document.body.appendChild(element);
        await flushPromises();

        const pendingList = element.shadowRoot.querySelector('c-todo-pending-list');
        const completedList = element.shadowRoot.querySelector('c-todo-completed-list');
        pendingList.refreshData = jest.fn();
        completedList.refreshData = jest.fn();

        pendingList.dispatchEvent(new CustomEvent('refreshlists'));
        await flushPromises();

        expect(pendingList.refreshData).toHaveBeenCalled();
        expect(completedList.refreshData).toHaveBeenCalled();
    });
});
