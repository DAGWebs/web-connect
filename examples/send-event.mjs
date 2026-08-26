const baseUrl = process.env.FIVEM_URL;
const token = process.env.FIVEM_API_TOKEN;

if (!baseUrl || !token) {
  throw new Error('Set FIVEM_URL and FIVEM_API_TOKEN');
}

const response = await fetch(`${baseUrl}/web-connect/events/announcement`, {
  method: 'POST',
  headers: {
    authorization: `Bearer ${token}`,
    'content-type': 'application/json',
  },
  body: JSON.stringify({ message: 'The race starts in five minutes!' }),
});

if (!response.ok) {
  throw new Error(`FiveM returned ${response.status}: ${await response.text()}`);
}

console.log(await response.json());
