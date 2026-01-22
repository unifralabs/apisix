For blockchain RPC providers (such as Alchemy, Infura, QuickNode), WebSocket (WS) billing logic is indeed more complex than HTTP because it involves **long-lived connection resource usage** and **passive data pushing**.

The industry's mainstream approach is to break down WebSocket behavior into three dimensions for billing: **Connection Count (Concurrency)**, **Subscription Actions (Requests)**, and **Push Load (Response/Push)**.

The most mature solution is the **"Everything is CU (Compute Unit)"** model. That is, every WebSocket action is converted into CUs.

Here is the detailed industry-standard billing strategy:

---

### 1. Core Billing Model: CU (Compute Unit) Billing Method

Do not sell WebSocket as "time"; sell it as "computation volume".

#### A. Establishing Connections & Subscription Requests (Handshake & Request)

When a user sends `eth_subscribe`, this is considered a high-consumption request.

*   **Billing Logic:** One subscription request = X CUs.
*   **Industry Reference:** Alchemy charges higher CUs for `eth_subscribe` than for a standard `eth_blockNumber` because it requires the node to maintain filters in memory.
*   **Example:** User sends `{"method": "eth_subscribe", "params": ["logs", ...]}` -> deduct 100 CUs.

#### B. Push Notifications —— This is the Billing Focus

This is the biggest difference from HTTP. The user doesn't send requests, but you are constantly sending data.

*   **Billing Logic:** For every message pushed to the client (JSON-RPC Notification), deduct Y CUs.
*   **Differentiated Pricing:** Different subscription types have different push costs.
    *   `newHeads` (New Block Headers): Cheap. Small data, fixed frequency (e.g., once every 12 seconds for Ethereum). **(e.g., 10 CU / push)**
    *   `logs` (Event Logs): Expensive. Requires matching against filters, and data volume can be large (e.g., listening for USDT Transfer events generates huge push volume during high concurrency). **(e.g., 20 CU / push)**
    *   `newPendingTransactions`: **Extremely Expensive**. Mempool data volume is huge and consumes massive bandwidth. Usually only open to premium plans or priced very high per push. **(e.g., 50 CU / push)**

#### C. Heartbeat & Maintenance (Heartbeat/Idle)

*   **Industry Practice:** Usually **not** billed by minute in CUs.
*   **Alternative:** Control resources via **Concurrent Connections**.
    *   Free Tier: Allows 5 concurrent WS connections.
    *   Paid Tier (10M quota): Allows 100 concurrent WS connections.
    *   Exceeding the limit results in direct rejection (HTTP 429 or WS Close code).

---

### 2. Industry Reference Cases (Alchemy & Infura)

| Billing Item | Action | Description | Estimated Weight (Example) |
| :--- | :--- | :--- | :--- |
| **Request** | `eth_subscribe` | Overhead of establishing a listener | **10 - 50 CU** |
| **Request** | `eth_unsubscribe` | Overhead of cleaning up resources | **10 CU** |
| **Push** | `newHeads` Event | Pushing a new block header | **10 - 20 CU / msg** |
| **Push** | `logs` Event | Pushing a contract log | **20 - 50 CU / msg** |
| **Limit** | Max Concurrent Connections | Server handle resource usage | **Tiered (Free: 5, Pro: 50)** |

**Why design it this way?**
If a user subscribes to an extremely active contract (like the Uniswap Router), your node might need to push dozens of messages per second. If you don't bill by "push count", a user could consume massive bandwidth and CPU with a single connection while you only collected a one-time subscription fee. This would be a loss.

---

### 3. Implementation Suggestions for Your Architecture (APISIX + Plugins)

Since you are developing the `processor-ws` plugin, it is recommended to implement billing using the following logic:

#### Step 1: Intercept Upstream Frames (Client -> Server)

When `method: "eth_subscribe"` is detected from the Client:

1.  Parse the request body.
2.  Call the billing center (Redis/PostgreSQL) and deduct a one-time "Subscription Fee" (e.g., 50 CU).
3.  If the balance is insufficient, return an Error directly and close the connection.

#### Step 2: Intercept Downstream Frames (Server -> Client)

This is the technical difficulty. You need to intercept the data stream returned by the RPC node to APISIX.
In APISIX's Lua plugin, you need to handle this in `body_filter` or the WebSocket frame processing stage:

1.  Detect that this is a `subscription` type response frame.
2.  **Async Billing:** Do not block sending. Let the data go out first, then asynchronously `DECR` the user's quota in Redis.
    *   *Optimization Tip:* If the push frequency is extremely high, use "Batch Billing" (Batch Debit), e.g., deduct the total amount once every 10 pushes to reduce Redis IO.
3.  **Circuit Breaker:** Periodically check the user's balance. If the balance is exhausted (hits zero), the backend service should actively send a WebSocket Close frame, disconnect, and stop pushing.

#### Step 3: Concurrency Control

Utilize APISIX's existing `limit-conn` plugin logic, or read the user's plan configuration in your `processor-ws`:

*   Redis Key: `ws_connections:{user_id}`
*   `INCR` on connection establishment, `DECR` on disconnection.
*   Reject handshake if `max_conn` allowed by the plan is exceeded.

### Summary

**WebSocket Billing Formula = (Subscription Request Count × Unit Price) + (Actual Pushed Message Count × Event Type Unit Price)**

*   **Simple Approach:** Deduct 10 points for every message pushed, regardless of the event.
*   **Granular Approach:** 10 points for block headers, 20 points for logs, 50 points for Pending transactions.

