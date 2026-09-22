// Displays a rotating motivational quote that auto-advances every 60 seconds.
// Users can also jump to any quote by clicking a dot indicator.
import { LightningElement, track } from 'lwc';

// ── Quote library ──────────────────────────────────────────────────────────

// Static array of quotes — adding a new entry here automatically extends the carousel.
const QUOTES = [
    { text: 'We are what we repeatedly do. Excellence, then, is not an act, but a habit.',                                         author: 'Aristotle' },
    { text: 'It always seems impossible until it\'s done.',                                                                        author: 'Nelson Mandela' },
    { text: 'Focus on being productive instead of busy.',                                                                          author: 'Tim Ferriss' },
    { text: 'You have power over your mind, not outside events. Realize this, and you will find strength.',                        author: 'Marcus Aurelius' },
    { text: 'You will face many defeats in life, but never let yourself be defeated.',                                             author: 'Maya Angelou' },
    { text: 'Your time is limited, so don\'t waste it living someone else\'s life.',                                               author: 'Steve Jobs' },
    { text: 'It is not that we have a short time to live, but that we waste a good deal of it.',                                   author: 'Seneca' },
    { text: 'Every action you take is a vote for the type of person you wish to become.',                                          author: 'James Clear' },
    { text: 'When we are no longer able to change a situation, we are challenged to change ourselves.',                            author: 'Viktor Frankl' },
    { text: 'Success is not final, failure is not fatal: it is the courage to continue that counts.',                              author: 'Winston Churchill' },
    { text: 'Make the best use of what is in your power, and take the rest as it happens.',                                        author: 'Epictetus' },
    { text: 'It does not matter how slowly you go as long as you do not stop.',                                                    author: 'Confucius' },
    { text: 'Do what you can, with what you have, where you are.',                                                                 author: 'Theodore Roosevelt' },
    { text: 'The journey of a thousand miles begins with one step.',                                                               author: 'Lao Tzu' },
    { text: 'What lies behind us and what lies before us are tiny matters compared to what lies within us.',                       author: 'Ralph Waldo Emerson' },
    { text: 'Clarity about what matters provides clarity about what does not.',                                                    author: 'Cal Newport' },
    { text: 'By failing to prepare, you are preparing to fail.',                                                                   author: 'Benjamin Franklin' },
    { text: 'He who has a why to live can bear almost any how.',                                                                   author: 'Friedrich Nietzsche' },
    { text: 'Vulnerability is not winning or losing; it\'s having the courage to show up when you can\'t control the outcome.',   author: 'Brené Brown' },
    { text: 'A person who never made a mistake never tried anything new.',                                                         author: 'Albert Einstein' }
];

const DURATION = 60; // seconds each quote is displayed before auto-advancing

// ── Component ──────────────────────────────────────────────────────────────

export default class MotivationalQuotes extends LightningElement {

    @track currentIndex = 0;    // index of the quote currently on screen
    @track countdown    = DURATION; // seconds remaining before the next quote
    @track isVisible    = true; // drives the CSS fade-in/out transition

    _ticker = null; // reference to the setInterval so we can clear it on destroy

    // ── Lifecycle ──────────────────────────────────────────────────────────

    // Start the countdown timer as soon as the component is added to the DOM.
    connectedCallback() {
        this._startTicker();
    }

    // Always clear the interval when the component is removed to avoid memory leaks.
    disconnectedCallback() {
        if (this._ticker) {
            clearInterval(this._ticker);
        }
    }

    // ── Timer ──────────────────────────────────────────────────────────────

    // Decrements the countdown every second; when it hits 0, advance to the next quote.
    _startTicker() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._ticker = setInterval(() => {
            this.countdown--;
            if (this.countdown === 0) {
                this.countdown = DURATION;
                this._advance();
            }
        }, 1000);
    }

    // Triggers the fade-out CSS class, waits 450 ms for the animation,
    // then swaps the quote and fades back in.
    _advance() {
        this.isVisible = false;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            // % wraps back to index 0 after the last quote
            this.currentIndex = (this.currentIndex + 1) % QUOTES.length;
            this.isVisible = true;
        }, 450);
    }

    // ── Dot click — jump to any quote ─────────────────────────────────────

    // Allows the user to skip directly to a specific quote by clicking its dot.
    // Resets the countdown so the new quote gets a full 60 seconds.
    handleDotClick(evt) {
        const idx = Number(evt.currentTarget.dataset.index);
        if (idx === this.currentIndex) return; // already on this quote — do nothing
        this.isVisible = false;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.currentIndex = idx;
            this.countdown    = DURATION; // reset timer for the newly selected quote
            this.isVisible    = true;
        }, 450);
    }

    // ── Getters ────────────────────────────────────────────────────────────

    // Returns the quote object currently being displayed.
    get currentQuote() {
        return QUOTES[this.currentIndex];
    }

    // Adds the '--hidden' modifier class to trigger the CSS fade-out animation.
    get quoteContentClass() {
        return `quote-content${this.isVisible ? '' : ' quote-content--hidden'}`;
    }

    // Calculates how wide the progress bar should be (0% → 100% over DURATION seconds).
    get progressStyle() {
        const pct = ((DURATION - this.countdown) / DURATION) * 100;
        return `width: ${pct}%`;
    }

    // Builds the dot indicator array. The active dot gets a CSS modifier class.
    get dots() {
        return QUOTES.map((_, i) => ({
            index : i,
            label : `Quote ${i + 1} of ${QUOTES.length}`,
            cls   : `dot${i === this.currentIndex ? ' dot--active' : ''}`
        }));
    }
}