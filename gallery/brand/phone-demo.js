// The live phone on dokkit.dev/phone.html: the Statement design as the Android and iOS apps have it, on made-up data.
// Built from the design mocks; runs inside an iframe the page sizes as an Android phone, an iPhone, or the iPhone Duo folded or open.
document.body.insertAdjacentHTML("afterbegin", '<svg xmlns="http://www.w3.org/2000/svg" style="display:none"><symbol id="i-arrow-left" viewBox="0 0 256 256"><path d="M224,128a8,8,0,0,1-8,8H59.31l58.35,58.34a8,8,0,0,1-11.32,11.32l-72-72a8,8,0,0,1,0-11.32l72-72a8,8,0,0,1,11.32,11.32L59.31,120H216A8,8,0,0,1,224,128Z"/></symbol><symbol id="i-arrow-right" viewBox="0 0 256 256"><path d="M221.66,133.66l-72,72a8,8,0,0,1-11.32-11.32L196.69,136H40a8,8,0,0,1,0-16H196.69L138.34,61.66a8,8,0,0,1,11.32-11.32l72,72A8,8,0,0,1,221.66,133.66Z"/></symbol><symbol id="i-arrows-clockwise" viewBox="0 0 256 256"><path d="M224,48V96a8,8,0,0,1-8,8H168a8,8,0,0,1,0-16h28.69L182.06,73.37a79.56,79.56,0,0,0-56.13-23.43h-.45A79.52,79.52,0,0,0,69.59,72.71,8,8,0,0,1,58.41,61.27a96,96,0,0,1,135,.79L208,76.69V48a8,8,0,0,1,16,0ZM186.41,183.29a80,80,0,0,1-112.47-.66L59.31,168H88a8,8,0,0,0,0-16H40a8,8,0,0,0-8,8v48a8,8,0,0,0,16,0V179.31l14.63,14.63A95.43,95.43,0,0,0,130,222.06h.53a95.36,95.36,0,0,0,67.07-27.33,8,8,0,0,0-11.18-11.44Z"/></symbol><symbol id="i-battery-high" viewBox="0 0 256 256"><path d="M200,56H32A24,24,0,0,0,8,80v96a24,24,0,0,0,24,24H200a24,24,0,0,0,24-24V80A24,24,0,0,0,200,56Zm8,120a8,8,0,0,1-8,8H32a8,8,0,0,1-8-8V80a8,8,0,0,1,8-8H200a8,8,0,0,1,8,8ZM144,96v64a8,8,0,0,1-16,0V96a8,8,0,0,1,16,0Zm-40,0v64a8,8,0,0,1-16,0V96a8,8,0,0,1,16,0ZM64,96v64a8,8,0,0,1-16,0V96a8,8,0,0,1,16,0Zm192,0v64a8,8,0,0,1-16,0V96a8,8,0,0,1,16,0Z"/></symbol><symbol id="i-calendar" viewBox="0 0 256 256"><path d="M208,32H184V24a8,8,0,0,0-16,0v8H88V24a8,8,0,0,0-16,0v8H48A16,16,0,0,0,32,48V208a16,16,0,0,0,16,16H208a16,16,0,0,0,16-16V48A16,16,0,0,0,208,32ZM72,48v8a8,8,0,0,0,16,0V48h80v8a8,8,0,0,0,16,0V48h24V80H48V48ZM208,208H48V96H208V208Zm-96-88v64a8,8,0,0,1-16,0V132.94l-4.42,2.22a8,8,0,0,1-7.16-14.32l16-8A8,8,0,0,1,112,120Zm59.16,30.45L152,176h16a8,8,0,0,1,0,16H136a8,8,0,0,1-6.4-12.8l28.78-38.37A8,8,0,1,0,145.07,132a8,8,0,1,1-13.85-8A24,24,0,0,1,176,136,23.76,23.76,0,0,1,171.16,150.45Z"/></symbol><symbol id="i-caret-down" viewBox="0 0 256 256"><path d="M213.66,101.66l-80,80a8,8,0,0,1-11.32,0l-80-80A8,8,0,0,1,53.66,90.34L128,164.69l74.34-74.35a8,8,0,0,1,11.32,11.32Z"/></symbol><symbol id="i-caret-right" viewBox="0 0 256 256"><path d="M181.66,133.66l-80,80a8,8,0,0,1-11.32-11.32L164.69,128,90.34,53.66a8,8,0,0,1,11.32-11.32l80,80A8,8,0,0,1,181.66,133.66Z"/></symbol><symbol id="i-cell-signal-full" viewBox="0 0 256 256"><path d="M168,72V200a8,8,0,0,1-16,0V72a8,8,0,0,1,16,0Zm32-48a8,8,0,0,0-8,8V200a8,8,0,0,0,16,0V32A8,8,0,0,0,200,24Zm-80,80a8,8,0,0,0-8,8v88a8,8,0,0,0,16,0V112A8,8,0,0,0,120,104ZM80,144a8,8,0,0,0-8,8v48a8,8,0,0,0,16,0V152A8,8,0,0,0,80,144ZM40,184a8,8,0,0,0-8,8v8a8,8,0,0,0,16,0v-8A8,8,0,0,0,40,184Z"/></symbol><symbol id="i-check" viewBox="0 0 256 256"><path d="M229.66,77.66l-128,128a8,8,0,0,1-11.32,0l-56-56a8,8,0,0,1,11.32-11.32L96,188.69,218.34,66.34a8,8,0,0,1,11.32,11.32Z"/></symbol><symbol id="i-check-circle" viewBox="0 0 256 256"><path d="M173.66,98.34a8,8,0,0,1,0,11.32l-56,56a8,8,0,0,1-11.32,0l-24-24a8,8,0,0,1,11.32-11.32L112,148.69l50.34-50.35A8,8,0,0,1,173.66,98.34ZM232,128A104,104,0,1,1,128,24,104.11,104.11,0,0,1,232,128Zm-16,0a88,88,0,1,0-88,88A88.1,88.1,0,0,0,216,128Z"/></symbol><symbol id="i-circle" viewBox="0 0 256 256"><path d="M128,24A104,104,0,1,0,232,128,104.11,104.11,0,0,0,128,24Zm0,192a88,88,0,1,1,88-88A88.1,88.1,0,0,1,128,216Z"/></symbol><symbol id="i-circle-dashed" viewBox="0 0 256 256"><path d="M96.26,37.05A8,8,0,0,1,102,27.29a104.11,104.11,0,0,1,52,0,8,8,0,0,1-2,15.75,8.15,8.15,0,0,1-2-.26,88.09,88.09,0,0,0-44,0A8,8,0,0,1,96.26,37.05ZM53.79,55.14a104.05,104.05,0,0,0-26,45,8,8,0,0,0,15.42,4.27,88,88,0,0,1,22-38.09A8,8,0,0,0,53.79,55.14ZM43.21,151.55a8,8,0,1,0-15.42,4.28,104.12,104.12,0,0,0,26,45,8,8,0,0,0,11.41-11.22A88.14,88.14,0,0,1,43.21,151.55ZM150,213.22a88,88,0,0,1-44,0,8,8,0,1,0-4,15.49,104.11,104.11,0,0,0,52,0,8,8,0,0,0-4-15.49ZM222.65,146a8,8,0,0,0-9.85,5.58,87.91,87.91,0,0,1-22,38.08,8,8,0,1,0,11.42,11.21,104,104,0,0,0,26-45A8,8,0,0,0,222.65,146Zm-9.86-41.54a8,8,0,0,0,15.42-4.28,104,104,0,0,0-26-45,8,8,0,1,0-11.41,11.22A88,88,0,0,1,212.79,104.45Z"/></symbol><symbol id="i-clock" viewBox="0 0 256 256"><path d="M128,24A104,104,0,1,0,232,128,104.11,104.11,0,0,0,128,24Zm0,192a88,88,0,1,1,88-88A88.1,88.1,0,0,1,128,216Zm64-88a8,8,0,0,1-8,8H128a8,8,0,0,1-8-8V72a8,8,0,0,1,16,0v48h48A8,8,0,0,1,192,128Z"/></symbol><symbol id="i-cloud" viewBox="0 0 256 256"><path d="M160,40A88.09,88.09,0,0,0,81.29,88.67,64,64,0,1,0,72,216h88a88,88,0,0,0,0-176Zm0,160H72a48,48,0,0,1,0-96c1.1,0,2.2,0,3.29.11A88,88,0,0,0,72,128a8,8,0,0,0,16,0,72,72,0,1,1,72,72Z"/></symbol><symbol id="i-device-mobile" viewBox="0 0 256 256"><path d="M176,16H80A24,24,0,0,0,56,40V216a24,24,0,0,0,24,24h96a24,24,0,0,0,24-24V40A24,24,0,0,0,176,16ZM72,64H184V192H72Zm8-32h96a8,8,0,0,1,8,8v8H72V40A8,8,0,0,1,80,32Zm96,192H80a8,8,0,0,1-8-8v-8H184v8A8,8,0,0,1,176,224Z"/></symbol><symbol id="i-eye-slash" viewBox="0 0 256 256"><path d="M53.92,34.62A8,8,0,1,0,42.08,45.38L61.32,66.55C25,88.84,9.38,123.2,8.69,124.76a8,8,0,0,0,0,6.5c.35.79,8.82,19.57,27.65,38.4C61.43,194.74,93.12,208,128,208a127.11,127.11,0,0,0,52.07-10.83l22,24.21a8,8,0,1,0,11.84-10.76Zm47.33,75.84,41.67,45.85a32,32,0,0,1-41.67-45.85ZM128,192c-30.78,0-57.67-11.19-79.93-33.25A133.16,133.16,0,0,1,25,128c4.69-8.79,19.66-33.39,47.35-49.38l18,19.75a48,48,0,0,0,63.66,70l14.73,16.2A112,112,0,0,1,128,192Zm6-95.43a8,8,0,0,1,3-15.72,48.16,48.16,0,0,1,38.77,42.64,8,8,0,0,1-7.22,8.71,6.39,6.39,0,0,1-.75,0,8,8,0,0,1-8-7.26A32.09,32.09,0,0,0,134,96.57Zm113.28,34.69c-.42.94-10.55,23.37-33.36,43.8a8,8,0,1,1-10.67-11.92A132.77,132.77,0,0,0,231.05,128a133.15,133.15,0,0,0-23.12-30.77C185.67,75.19,158.78,64,128,64a118.37,118.37,0,0,0-19.36,1.57A8,8,0,1,1,106,49.79,134,134,0,0,1,128,48c34.88,0,66.57,13.26,91.66,38.35,18.83,18.83,27.3,37.62,27.65,38.41A8,8,0,0,1,247.31,131.26Z"/></symbol><symbol id="i-gear" viewBox="0 0 256 256"><path d="M128,80a48,48,0,1,0,48,48A48.05,48.05,0,0,0,128,80Zm0,80a32,32,0,1,1,32-32A32,32,0,0,1,128,160Zm88-29.84q.06-2.16,0-4.32l14.92-18.64a8,8,0,0,0,1.48-7.06,107.21,107.21,0,0,0-10.88-26.25,8,8,0,0,0-6-3.93l-23.72-2.64q-1.48-1.56-3-3L186,40.54a8,8,0,0,0-3.94-6,107.71,107.71,0,0,0-26.25-10.87,8,8,0,0,0-7.06,1.49L130.16,40Q128,40,125.84,40L107.2,25.11a8,8,0,0,0-7.06-1.48A107.6,107.6,0,0,0,73.89,34.51a8,8,0,0,0-3.93,6L67.32,64.27q-1.56,1.49-3,3L40.54,70a8,8,0,0,0-6,3.94,107.71,107.71,0,0,0-10.87,26.25,8,8,0,0,0,1.49,7.06L40,125.84Q40,128,40,130.16L25.11,148.8a8,8,0,0,0-1.48,7.06,107.21,107.21,0,0,0,10.88,26.25,8,8,0,0,0,6,3.93l23.72,2.64q1.49,1.56,3,3L70,215.46a8,8,0,0,0,3.94,6,107.71,107.71,0,0,0,26.25,10.87,8,8,0,0,0,7.06-1.49L125.84,216q2.16.06,4.32,0l18.64,14.92a8,8,0,0,0,7.06,1.48,107.21,107.21,0,0,0,26.25-10.88,8,8,0,0,0,3.93-6l2.64-23.72q1.56-1.48,3-3L215.46,186a8,8,0,0,0,6-3.94,107.71,107.71,0,0,0,10.87-26.25,8,8,0,0,0-1.49-7.06Zm-16.1-6.5a73.93,73.93,0,0,1,0,8.68,8,8,0,0,0,1.74,5.48l14.19,17.73a91.57,91.57,0,0,1-6.23,15L187,173.11a8,8,0,0,0-5.1,2.64,74.11,74.11,0,0,1-6.14,6.14,8,8,0,0,0-2.64,5.1l-2.51,22.58a91.32,91.32,0,0,1-15,6.23l-17.74-14.19a8,8,0,0,0-5-1.75h-.48a73.93,73.93,0,0,1-8.68,0,8,8,0,0,0-5.48,1.74L100.45,215.8a91.57,91.57,0,0,1-15-6.23L82.89,187a8,8,0,0,0-2.64-5.1,74.11,74.11,0,0,1-6.14-6.14,8,8,0,0,0-5.1-2.64L46.43,170.6a91.32,91.32,0,0,1-6.23-15l14.19-17.74a8,8,0,0,0,1.74-5.48,73.93,73.93,0,0,1,0-8.68,8,8,0,0,0-1.74-5.48L40.2,100.45a91.57,91.57,0,0,1,6.23-15L69,82.89a8,8,0,0,0,5.1-2.64,74.11,74.11,0,0,1,6.14-6.14A8,8,0,0,0,82.89,69L85.4,46.43a91.32,91.32,0,0,1,15-6.23l17.74,14.19a8,8,0,0,0,5.48,1.74,73.93,73.93,0,0,1,8.68,0,8,8,0,0,0,5.48-1.74L155.55,40.2a91.57,91.57,0,0,1,15,6.23L173.11,69a8,8,0,0,0,2.64,5.1,74.11,74.11,0,0,1,6.14,6.14,8,8,0,0,0,5.1,2.64l22.58,2.51a91.32,91.32,0,0,1,6.23,15l-14.19,17.74A8,8,0,0,0,199.87,123.66Z"/></symbol><symbol id="i-hand-waving" viewBox="0 0 256 256"><path d="M220.17,100,202.86,70a28,28,0,0,0-38.24-10.25,27.69,27.69,0,0,0-9,8.34L138.2,38a28,28,0,0,0-48.48,0A28,28,0,0,0,48.15,74l1.59,2.76A27.67,27.67,0,0,0,38,80.41a28,28,0,0,0-10.24,38.25l40,69.32a87.47,87.47,0,0,0,53.43,41,88.56,88.56,0,0,0,22.92,3,88,88,0,0,0,76.06-132Zm-6.66,62.64A72,72,0,0,1,81.62,180l-40-69.32a12,12,0,0,1,20.78-12L81.63,132a8,8,0,1,0,13.85-8L62,66A12,12,0,1,1,82.78,54L114,108a8,8,0,1,0,13.85-8L103.57,58h0a12,12,0,1,1,20.78-12l33.42,57.9a48,48,0,0,0-5.54,60.6,8,8,0,0,0,13.24-9A32,32,0,0,1,172.78,112a8,8,0,0,0,2.13-10.4L168.23,90A12,12,0,1,1,189,78l17.31,30A71.56,71.56,0,0,1,213.51,162.62ZM184.25,31.71A8,8,0,0,1,194,26a59.62,59.62,0,0,1,36.53,28l.33.57a8,8,0,1,1-13.85,8l-.33-.57a43.67,43.67,0,0,0-26.8-20.5A8,8,0,0,1,184.25,31.71ZM80.89,237a8,8,0,0,1-11.23,1.33A119.56,119.56,0,0,1,40.06,204a8,8,0,0,1,13.86-8,103.67,103.67,0,0,0,25.64,29.72A8,8,0,0,1,80.89,237Z"/></symbol><symbol id="i-hard-drives" viewBox="0 0 256 256"><path d="M208,136H48a16,16,0,0,0-16,16v48a16,16,0,0,0,16,16H208a16,16,0,0,0,16-16V152A16,16,0,0,0,208,136Zm0,64H48V152H208v48Zm0-160H48A16,16,0,0,0,32,56v48a16,16,0,0,0,16,16H208a16,16,0,0,0,16-16V56A16,16,0,0,0,208,40Zm0,64H48V56H208v48ZM192,80a12,12,0,1,1-12-12A12,12,0,0,1,192,80Zm0,96a12,12,0,1,1-12-12A12,12,0,0,1,192,176Z"/></symbol><symbol id="i-hourglass-medium" viewBox="0 0 256 256"><path d="M200,75.64V40a16,16,0,0,0-16-16H72A16,16,0,0,0,56,40V76a16.07,16.07,0,0,0,6.4,12.8L114.67,128,62.4,167.2A16.07,16.07,0,0,0,56,180v36a16,16,0,0,0,16,16H184a16,16,0,0,0,16-16V180.36a16.09,16.09,0,0,0-6.35-12.77L141.27,128l52.38-39.6A16.05,16.05,0,0,0,200,75.64ZM72,40H184V75.64L178.23,80H77.33L72,76Zm56,78L98.67,96h58.4Zm56,98H72V180l48-36v24a8,8,0,0,0,16,0V144.08l48,36.28Z"/></symbol><symbol id="i-house" viewBox="0 0 256 256"><path d="M219.31,108.68l-80-80a16,16,0,0,0-22.62,0l-80,80A15.87,15.87,0,0,0,32,120v96a8,8,0,0,0,8,8h64a8,8,0,0,0,8-8V160h32v56a8,8,0,0,0,8,8h64a8,8,0,0,0,8-8V120A15.87,15.87,0,0,0,219.31,108.68ZM208,208H160V152a8,8,0,0,0-8-8H104a8,8,0,0,0-8,8v56H48V120l80-80,80,80Z"/></symbol><symbol id="i-info" viewBox="0 0 256 256"><path d="M128,24A104,104,0,1,0,232,128,104.11,104.11,0,0,0,128,24Zm0,192a88,88,0,1,1,88-88A88.1,88.1,0,0,1,128,216Zm16-40a8,8,0,0,1-8,8,16,16,0,0,1-16-16V128a8,8,0,0,1,0-16,16,16,0,0,1,16,16v40A8,8,0,0,1,144,176ZM112,84a12,12,0,1,1,12,12A12,12,0,0,1,112,84Z"/></symbol><symbol id="i-lock-simple" viewBox="0 0 256 256"><path d="M208,80H176V56a48,48,0,0,0-96,0V80H48A16,16,0,0,0,32,96V208a16,16,0,0,0,16,16H208a16,16,0,0,0,16-16V96A16,16,0,0,0,208,80ZM96,56a32,32,0,0,1,64,0V80H96ZM208,208H48V96H208V208Z"/></symbol><symbol id="i-moon" viewBox="0 0 256 256"><path d="M233.54,142.23a8,8,0,0,0-8-2,88.08,88.08,0,0,1-109.8-109.8,8,8,0,0,0-10-10,104.84,104.84,0,0,0-52.91,37A104,104,0,0,0,136,224a103.09,103.09,0,0,0,62.52-20.88,104.84,104.84,0,0,0,37-52.91A8,8,0,0,0,233.54,142.23ZM188.9,190.34A88,88,0,0,1,65.66,67.11a89,89,0,0,1,31.4-26A106,106,0,0,0,96,56,104.11,104.11,0,0,0,200,160a106,106,0,0,0,14.92-1.06A89,89,0,0,1,188.9,190.34Z"/></symbol><symbol id="i-palette" viewBox="0 0 256 256"><path d="M200.77,53.89A103.27,103.27,0,0,0,128,24h-1.07A104,104,0,0,0,24,128c0,43,26.58,79.06,69.36,94.17A32,32,0,0,0,136,192a16,16,0,0,1,16-16h46.21a31.81,31.81,0,0,0,31.2-24.88,104.43,104.43,0,0,0,2.59-24A103.28,103.28,0,0,0,200.77,53.89Zm13,93.71A15.89,15.89,0,0,1,198.21,160H152a32,32,0,0,0-32,32,16,16,0,0,1-21.31,15.07C62.49,194.3,40,164,40,128a88,88,0,0,1,87.09-88h.9a88.35,88.35,0,0,1,88,87.25A88.86,88.86,0,0,1,213.81,147.6ZM140,76a12,12,0,1,1-12-12A12,12,0,0,1,140,76ZM96,100A12,12,0,1,1,84,88,12,12,0,0,1,96,100Zm0,56a12,12,0,1,1-12-12A12,12,0,0,1,96,156Zm88-56a12,12,0,1,1-12-12A12,12,0,0,1,184,100Z"/></symbol><symbol id="i-plus" viewBox="0 0 256 256"><path d="M224,128a8,8,0,0,1-8,8H136v80a8,8,0,0,1-16,0V136H40a8,8,0,0,1,0-16h80V40a8,8,0,0,1,16,0v80h80A8,8,0,0,1,224,128Z"/></symbol><symbol id="i-sliders-horizontal" viewBox="0 0 256 256"><path d="M40,88H73a32,32,0,0,0,62,0h81a8,8,0,0,0,0-16H135a32,32,0,0,0-62,0H40a8,8,0,0,0,0,16Zm64-24A16,16,0,1,1,88,80,16,16,0,0,1,104,64ZM216,168H199a32,32,0,0,0-62,0H40a8,8,0,0,0,0,16h97a32,32,0,0,0,62,0h17a8,8,0,0,0,0-16Zm-48,24a16,16,0,1,1,16-16A16,16,0,0,1,168,192Z"/></symbol><symbol id="i-squares-four" viewBox="0 0 256 256"><path d="M104,40H56A16,16,0,0,0,40,56v48a16,16,0,0,0,16,16h48a16,16,0,0,0,16-16V56A16,16,0,0,0,104,40Zm0,64H56V56h48v48Zm96-64H152a16,16,0,0,0-16,16v48a16,16,0,0,0,16,16h48a16,16,0,0,0,16-16V56A16,16,0,0,0,200,40Zm0,64H152V56h48v48Zm-96,32H56a16,16,0,0,0-16,16v48a16,16,0,0,0,16,16h48a16,16,0,0,0,16-16V152A16,16,0,0,0,104,136Zm0,64H56V152h48v48Zm96-64H152a16,16,0,0,0-16,16v48a16,16,0,0,0,16,16h48a16,16,0,0,0,16-16V152A16,16,0,0,0,200,136Zm0,64H152V152h48v48Z"/></symbol><symbol id="i-swap" viewBox="0 0 256 256"><path d="M224,48V152a16,16,0,0,1-16,16H99.31l10.35,10.34a8,8,0,0,1-11.32,11.32l-24-24a8,8,0,0,1,0-11.32l24-24a8,8,0,0,1,11.32,11.32L99.31,152H208V48H96v8a8,8,0,0,1-16,0V48A16,16,0,0,1,96,32H208A16,16,0,0,1,224,48ZM168,192a8,8,0,0,0-8,8v8H48V104H156.69l-10.35,10.34a8,8,0,0,0,11.32,11.32l24-24a8,8,0,0,0,0-11.32l-24-24a8,8,0,0,0-11.32,11.32L156.69,88H48a16,16,0,0,0-16,16V208a16,16,0,0,0,16,16H160a16,16,0,0,0,16-16v-8A8,8,0,0,0,168,192Z"/></symbol><symbol id="i-trash" viewBox="0 0 256 256"><path d="M216,48H176V40a24,24,0,0,0-24-24H104A24,24,0,0,0,80,40v8H40a8,8,0,0,0,0,16h8V208a16,16,0,0,0,16,16H192a16,16,0,0,0,16-16V64h8a8,8,0,0,0,0-16ZM96,40a8,8,0,0,1,8-8h48a8,8,0,0,1,8,8v8H96Zm96,168H64V64H192ZM112,104v64a8,8,0,0,1-16,0V104a8,8,0,0,1,16,0Zm48,0v64a8,8,0,0,1-16,0V104a8,8,0,0,1,16,0Z"/></symbol><symbol id="i-warning" viewBox="0 0 256 256"><path d="M236.8,188.09,149.35,36.22h0a24.76,24.76,0,0,0-42.7,0L19.2,188.09a23.51,23.51,0,0,0,0,23.72A24.35,24.35,0,0,0,40.55,224h174.9a24.35,24.35,0,0,0,21.33-12.19A23.51,23.51,0,0,0,236.8,188.09ZM222.93,203.8a8.5,8.5,0,0,1-7.48,4.2H40.55a8.5,8.5,0,0,1-7.48-4.2,7.59,7.59,0,0,1,0-7.72L120.52,44.21a8.75,8.75,0,0,1,15,0l87.45,151.87A7.59,7.59,0,0,1,222.93,203.8ZM120,144V104a8,8,0,0,1,16,0v40a8,8,0,0,1-16,0Zm20,36a12,12,0,1,1-12-12A12,12,0,0,1,140,180Z"/></symbol><symbol id="i-warning-octagon" viewBox="0 0 256 256"><path d="M120,136V80a8,8,0,0,1,16,0v56a8,8,0,0,1-16,0ZM232,91.55v72.9a15.86,15.86,0,0,1-4.69,11.31l-51.55,51.55A15.86,15.86,0,0,1,164.45,232H91.55a15.86,15.86,0,0,1-11.31-4.69L28.69,175.76A15.86,15.86,0,0,1,24,164.45V91.55a15.86,15.86,0,0,1,4.69-11.31L80.24,28.69A15.86,15.86,0,0,1,91.55,24h72.9a15.86,15.86,0,0,1,11.31,4.69l51.55,51.55A15.86,15.86,0,0,1,232,91.55Zm-16,0L164.45,40H91.55L40,91.55v72.9L91.55,216h72.9L216,164.45ZM128,160a12,12,0,1,0,12,12A12,12,0,0,0,128,160Z"/></symbol><symbol id="i-wifi-high" viewBox="0 0 256 256"><path d="M140,204a12,12,0,1,1-12-12A12,12,0,0,1,140,204ZM237.08,87A172,172,0,0,0,18.92,87,8,8,0,0,0,29.08,99.37a156,156,0,0,1,197.84,0A8,8,0,0,0,237.08,87ZM205,122.77a124,124,0,0,0-153.94,0A8,8,0,0,0,61,135.31a108,108,0,0,1,134.06,0,8,8,0,0,0,11.24-1.3A8,8,0,0,0,205,122.77Zm-32.26,35.76a76.05,76.05,0,0,0-89.42,0,8,8,0,0,0,9.42,12.94,60,60,0,0,1,70.58,0,8,8,0,1,0,9.42-12.94Z"/></symbol><symbol id="i-x" viewBox="0 0 256 256"><path d="M205.66,194.34a8,8,0,0,1-11.32,11.32L128,139.31,61.66,205.66a8,8,0,0,1-11.32-11.32L116.69,128,50.34,61.66A8,8,0,0,1,61.66,50.34L128,116.69l66.34-66.35a8,8,0,0,1,11.32,11.32L139.31,128Z"/></symbol></svg>');

// The page tells the app which device it is in; the frame around it is drawn by the page.
(function () {
  var q = new URLSearchParams(location.search);
  document.documentElement.dataset.device = q.get("device") || "android";
  window.addEventListener("message", function (e) {
    if (e.origin !== location.origin || !e.data || e.data.type !== "dokkit-device") return;
    document.documentElement.dataset.device = e.data.device;
    window.dispatchEvent(new Event("resize"));
  });
})();
// Made-up estate for the Android direction mocks, in the shape of the phone snapshot (spec/phone-cases/snapshot.json).
// Every direction reads this file, so they all show the same servers, machines, services and issues.
window.PHONE = (function () {
  var now = Date.now(), MIN = 60000, HR = 60 * MIN;
  var at = function (minutesAgo) { return new Date(now - minutesAgo * MIN).toISOString(); };
  var ahead = function (minutes) { return new Date(now + minutes * MIN).toISOString(); };

  function svc(id, machine, name, state, extra) {
    var s = { id: id, machine: machine, name: name, kind: "service", state: state, environment: "production", version: null, note: null, checks: [], chart: { metric: null, values: [] } };
    for (var k in extra) s[k] = extra[k];
    return s;
  }
  function chart(base, spread, tail) {
    return Array.from({ length: 24 }, function (_, i) {
      var v = base + Math.round(Math.sin(i / 2.3) * spread + (i % 5) * spread / 6);
      return tail && i >= 24 - tail.length ? tail[i - (24 - tail.length)] : Math.max(0, v);
    });
  }

  var services = [
    // db-01
    svc("s-postgres", "db-01", "postgres", "ok", { checks: [{ name: "port 5432", type: "tcp", state: "ok", checked_at: at(0.4) }], chart: { metric: "connections", values: chart(42, 8) } }),
    svc("s-pgbouncer", "db-01", "pgbouncer", "ok"),
    svc("s-wal", "db-01", "wal-archive", "ok"),
    svc("s-pgexp", "db-01", "pg-exporter", "ok"),
    svc("s-replica", "db-01", "replica-sync", "ok"),
    svc("s-purge", "db-01", "nightly-purge", "down", { kind: "job", note: "Expected at 01:00. Its last good run was yesterday at 01:04 and took 4 minutes.",
      checks: [{ name: "schedule", type: "job", state: "down", note: "Missed its 01:00 start, with 20 minutes' grace.", checked_at: at(1) }] }),
    // web-02
    svc("s-nginx", "web-02", "nginx", "ok"),
    svc("s-upload", "web-02", "upload-portal", "degraded", { version: "2.4.1", note: "Three checks in a row took over two seconds.",
      checks: [
        { name: "GET /health", type: "http", state: "degraded", note: "Answered in 2.4 s. The limit is 2 s.", checked_at: at(0.5) },
        { name: "process", type: "process", state: "ok", checked_at: at(0.5) },
        { name: "port 8080", type: "tcp", state: "ok", checked_at: at(0.5) }
      ], chart: { metric: "response time, ms", values: chart(380, 90, [1650, 1980, 2310, 2440]) } }),
    svc("s-api", "web-02", "api", "ok", { version: "7.12.0", chart: { metric: "requests a minute", values: chart(820, 160) } }),
    svc("s-queue", "web-02", "worker-queue", "ok"),
    svc("s-redis", "web-02", "redis", "ok"),
    svc("s-resize", "web-02", "resize-worker", "ok"),
    svc("s-session", "web-02", "session-store", "ok"),
    svc("s-search", "web-02", "search-index", "ok"),
    svc("s-imgcache", "web-02", "image-cache", "ok"),
    svc("s-cdnsync", "web-02", "cdn-sync", "ok"),
    svc("s-pay", "web-02", "payment-gateway", "ok"),
    svc("s-upload-stg", "web-02", "upload-portal", "degraded", { environment: "staging" }),
    // nas
    svc("s-disk", "nas", "disk /data", "degraded", { kind: "threshold", note: "91 percent full. The limit is 90.", chart: { metric: "used, %", values: chart(84, 1, [89, 90, 90, 91]) },
      checks: [{ name: "disk /data", type: "threshold", state: "degraded", note: "91.0 percent used, limit 90.", checked_at: at(0.6) }] }),
    svc("s-smb", "nas", "smb-share", "ok"),
    svc("s-nfs", "nas", "nfs-export", "ok"),
    svc("s-backup", "nas", "backup", "ok", { kind: "job" }),
    svc("s-snapkeep", "nas", "snapshot-keeper", "ok"),
    svc("s-smart", "nas", "smart-monitor", "unknown"),
    svc("s-photo", "nas", "photo-sync", "ok"),
    // mail
    svc("s-postfix", "mail", "postfix", "ok"),
    svc("s-dovecot", "mail", "dovecot", "ok"),
    svc("s-spam", "mail", "spam-filter", "ok"),
    svc("s-tls", "mail", "mail-tls", "ok", { kind: "expiry", note: "The certificate expires in 21 days.",
      checks: [{ name: "certificate", type: "expiry", state: "ok", note: "21 days left.", checked_at: at(30) }] }),
    svc("s-webmail", "mail", "webmail", "ok"),
    svc("s-av", "mail", "antivirus", "ok"),
    // build
    svc("s-ci", "build", "ci-runner", "ok"),
    svc("s-artifact", "build", "artifact-store", "ok"),
    svc("s-docker", "build", "docker-daemon", "ok"),
    svc("s-mirror", "build", "package-mirror", "unknown"),
    svc("s-nbuild", "build", "nightly-build", "ok", { kind: "job" }),
    svc("s-preview", "build", "web-preview", "down", { environment: "dev", note: "Connection refused" }),
    // sql
    svc("s-sqlsrv", "sql", "sql-server", "ok"),
    svc("s-sqlagent", "sql", "sql-agent", "ok"),
    svc("s-reports", "sql", "report-builder", "degraded", { note: "Reports take over a minute.",
      checks: [{ name: "GET /reports/health", type: "http", state: "degraded", note: "Answered in 64 s.", checked_at: at(0.7) }] }),
    svc("s-etl", "sql", "etl-loader", "ok"),
    // front-desk-pc: down, in planned downtime
    svc("s-fdagent", "front-desk-pc", "check-in kiosk", "ok"),
    // not on a machine
    svc("s-site", "g-web", "public website", "ok", { kind: "http", chart: { metric: "response time, ms", values: chart(210, 40) } }),
    svc("s-status", "g-web", "status page", "ok", { kind: "http" }),
    svc("s-dns", "g-cloud", "dns", "ok", { kind: "dns" }),
    svc("s-payapi", "g-cloud", "payments api", "unknown", { kind: "http" })
  ];

  function onMachine(id) { return services.filter(function (s) { return s.machine === id; }); }

  var machines = [
    { id: "db-01", name: "db-01", os: "linux", kind: "enrolled", down: false, last_seen_at: at(0.3),
      vitals: { "cpu.percent": 38, "memory.used_percent": 61, "disk.used_percent./": 72 } },
    { id: "web-02", name: "web-02", os: "linux", kind: "enrolled", down: false, last_seen_at: at(0.2),
      vitals: { "cpu.percent": 64, "memory.used_percent": 58, "disk.used_percent./": 44 } },
    { id: "nas", name: "nas", os: "linux", kind: "enrolled", down: false, last_seen_at: at(0.4),
      vitals: { "cpu.percent": 12, "memory.used_percent": 33, "disk.used_percent./": 41, "disk.used_percent./data": 91 } },
    { id: "mail", name: "mail", os: "linux", kind: "enrolled", down: false, last_seen_at: at(0.5),
      vitals: { "cpu.percent": 9, "memory.used_percent": 41, "disk.used_percent./": 37 } },
    { id: "build", name: "build", os: "windows", kind: "enrolled", down: false, last_seen_at: at(0.6),
      vitals: { "cpu.percent": 22, "memory.used_percent": 47, "disk.used_percent.C:": 63 },
      schedules: [{ id: "q1", reason: "Windows updates", next: ahead(60 * 26) }] },
    { id: "sql", name: "sql", os: "windows", kind: "enrolled", down: false, last_seen_at: at(0.4),
      vitals: { "cpu.percent": 31, "memory.used_percent": 88, "disk.used_percent.D:": 58 } },
    { id: "front-desk-pc", name: "front-desk-pc", os: "windows", kind: "enrolled", down: true, last_seen_at: at(170),
      vitals: {}, planned_downtime: { until: ahead(60 * 11), reason: "Off outside office hours" } },
    { id: "g-web", name: "Websites", kind: "group", down: false, vitals: {} },
    { id: "g-cloud", name: "Cloud", kind: "group", down: false, vitals: {} }
  ];
  machines.forEach(function (m) { m.services = onMachine(m.id); });

  function issue(o) {
    var base = { count: 1, acknowledged_at: null, snoozed_until: null, closed_at: null, alert: { channel: "push", status: "sent" }, history: [] };
    for (var k in o) base[k] = o[k];
    return base;
  }
  var issues = [
    issue({ id: "i3", short_id: "DOK-3", title: "Nightly purge did not run", kind: "job", machine: "db-01", service: "s-purge", state: "down", since: at(21 * 60 + 30),
      note: "Expected at 01:00. Its last good run was yesterday at 01:04 and took 4 minutes.", alert: { channel: "page", status: "sent" },
      history: [{ at: at(21 * 60 + 30), event: "opened" }, { at: at(21 * 60 + 29), event: "paged", note: "on call" }] }),
    issue({ id: "i7", short_id: "DOK-7", title: "Upload portal answers slowly", kind: "custom", machine: "web-02", service: "s-upload", state: "degraded", since: at(40), count: 3,
      note: "Three checks in a row took over two seconds. It started 20 minutes after deploy 2.4.1.", acknowledged_at: at(12),
      history: [{ at: at(40), event: "opened" }, { at: at(25), event: "reopened" }, { at: at(12), event: "acknowledged", by: "alex" }] }),
    issue({ id: "i4", short_id: "DOK-4", title: "Disk /data is nearly full", kind: "threshold", machine: "nas", service: "s-disk", state: "degraded", since: at(10),
      note: "91 percent full. The limit is 90. At this week's rate it is full in about 12 days.", alert: { channel: "push", status: "held", until: ahead(60 * 9) },
      history: [{ at: at(10), event: "opened" }, { at: at(9), event: "held", note: "night hours" }] }),
    issue({ id: "i8", short_id: "DOK-8", title: "Certificate for mail expires in 21 days", kind: "expiry", machine: "mail", service: "s-tls", state: "degraded", soon: true, since: at(120),
      note: "It expires on " + new Date(now + 21 * 24 * HR).toDateString() + ".", history: [{ at: at(120), event: "opened" }] }),
    issue({ id: "i5", short_id: "DOK-5", title: "Disk /data full in about 12 days", kind: "forecast", machine: "nas", service: "s-disk", state: "degraded", soon: true, since: at(30),
      note: "Forecast from the last week of readings.", history: [{ at: at(30), event: "opened" }] }),
    issue({ id: "i9", short_id: "DOK-9", title: "Report builder is slow", kind: "http", machine: "sql", service: "s-reports", state: "degraded", since: at(360),
      note: "Reports take over a minute.", snoozed_until: ahead(150),
      history: [{ at: at(360), event: "opened" }, { at: at(300), event: "snoozed", until: ahead(150), by: "alex" }] }),
    issue({ id: "i10", short_id: "DOK-10", title: "Web preview is down", kind: "http", machine: "build", service: "s-preview", state: "down", since: at(90), alert: null,
      note: "Connection refused.", history: [{ at: at(90), event: "opened" }] })
  ];
  function byId(id) { return issues.find(function (i) { return i.id === id; }); }
  services.forEach(function (s) { s.open_issue = issues.find(function (i) { return i.service === s.id && !i.closed_at && !i.soon; }) || null; });

  var jobs = [
    { id: "s-purge", machine: "db-01", name: "nightly-purge", state: "down", schedule: "0 1 * * *", next_expected: ahead(60 * 2 + 30), last_good_run: at(45 * 60),
      last_run: { result: "ok", exit_code: 0, duration_ms: 240000, started_at: at(45 * 60) } },
    { id: "s-backup", machine: "nas", name: "backup", state: "ok", schedule: "after midnight", next_expected: ahead(60 * 8), last_good_run: at(200),
      last_run: { result: "ok", exit_code: 0, duration_ms: 3120000, started_at: at(252) } },
    { id: "s-nbuild", machine: "build", name: "nightly-build", state: "ok", schedule: "on push", last_good_run: at(60 * 9),
      last_run: { result: "running", started_at: at(6), done: 4000, total: 9000 } }
  ];

  var logs = {
    "s-upload": [
      { t: at(0.4), level: "error", msg: "resize timed out after 30 s" }, { t: at(0.9), level: "info", msg: "upload received" },
      { t: at(1.4), level: "info", msg: "thumbnail made" }, { t: at(2), level: "warn", msg: "slow answer: 2.4 s" },
      { t: at(2.6), level: "info", msg: "virus scan passed" }, { t: at(3.1), level: "error", msg: "resize timed out after 30 s" },
      { t: at(3.7), level: "info", msg: "stored in the share" }, { t: at(4.4), level: "info", msg: "upload received" }
    ],
    "s-purge": [
      { t: at(45 * 60 - 4), level: "info", msg: "Purged 17,422 rows" }, { t: at(45 * 60 - 1), level: "info", msg: "vacuum started" },
      { t: at(45 * 60), level: "info", msg: "purge started" }
    ],
    "s-reports": [{ t: at(1), level: "warn", msg: "query took 64 s: monthly-sales" }, { t: at(6), level: "info", msg: "report queued" }]
  };

  // 48 half hours per machine, oldest first: ok, warn, bad, off (not expected), none (no data).
  // The phone snapshot does not carry this yet; it is here to show the design.
  function lastDay(id) {
    return Array.from({ length: 48 }, function (_, i) {
      var h = new Date(now - (47 - i) * 30 * MIN).getHours();
      if (id === "front-desk-pc") return h >= 8 && h < 18 ? "ok" : "off";
      if (id === "db-01") return i === 5 ? "bad" : "ok";
      if (id === "web-02") return i > 45 ? "warn" : i === 30 ? "warn" : "ok";
      if (id === "nas") return i > 46 ? "warn" : "ok";
      if (id === "sql") return i > 35 ? "warn" : "ok";
      return "ok";
    });
  }

  var snapshot = {
    schema: 1,
    server: { name: "northwind", version: "v0.4.2", made_at: at(0.7), counter: 1791937925, left_out: [] },
    inbox: {
      needs_you: [byId("i3"), byId("i7"), byId("i4")],
      soon: [byId("i8"), byId("i5")],
      snoozed: [byId("i9")],
      not_watched: [
        { id: "f1", machine: "build", name: "22", kind: "port", detail: { label: "Port 22", saw: "sshd" } },
        { id: "f2", machine: "build", name: "Spooler", kind: "service", detail: { label: "Print Spooler", saw: "Running" } },
        { id: "f3", machine: "sql", name: "defrag", kind: "job", detail: { label: "defrag", saw: "Sundays 03:00" } }
      ],
      other_environments: [{ environment: "dev", issues: [byId("i10")] }],
      fine: { services: services.filter(function (s) { return s.state === "ok"; }).length, machines: 6 }
    },
    machines: machines, services: services, issues: issues, jobs: jobs, logs: logs
  };

  // A second paired server, small and calm, so the server picker and the Servers list have something to show.
  var lab = {
    schema: 1,
    server: { name: "harbor-lab", version: "v0.4.2", made_at: at(1.2), counter: 88213, left_out: [] },
    inbox: { needs_you: [], soon: [], snoozed: [], not_watched: [], other_environments: [], fine: { services: 5, machines: 2 } },
    machines: [
      { id: "pi-4", name: "pi-4", os: "linux", kind: "enrolled", down: false, last_seen_at: at(0.5), vitals: { "cpu.percent": 7, "memory.used_percent": 29, "disk.used_percent./": 52 },
        services: [svc("l1", "pi-4", "home-assistant", "ok"), svc("l2", "pi-4", "mqtt", "ok"), svc("l3", "pi-4", "zigbee2mqtt", "ok")] },
      { id: "nuc", name: "nuc", os: "linux", kind: "enrolled", down: false, last_seen_at: at(0.4), vitals: { "cpu.percent": 18, "memory.used_percent": 44, "disk.used_percent./": 66 },
        services: [svc("l4", "nuc", "plex", "ok"), svc("l5", "nuc", "backup", "ok", { kind: "job" })] }
    ],
    services: [], issues: [], jobs: [], logs: {}
  };
  lab.services = lab.machines.reduce(function (a, m) { return a.concat(m.services); }, []);

  var servers = [
    { id: "mb-northwind", name: "northwind", relay: "https://relay.example.net", added_at: at(60 * 24 * 12), state: { snapshot: snapshot, made_at: snapshot.server.made_at, problem: null } },
    { id: "mb-lab", name: "harbor-lab", relay: "https://relay.example.net", added_at: at(60 * 24 * 3), state: { snapshot: lab, made_at: lab.server.made_at, problem: null } }
  ];

  return { now: now, at: at, ahead: ahead, servers: servers, lastDay: lastDay };
})();

// What every direction shows, worked out the way the Android app does it today (core/Home.kt, core/Screens.kt),
// plus the scenarios the review page switches between and the phone settings with their defaults.
window.CORE = (function () {
  var P = window.PHONE, MIN = 60000;
  var q = new URLSearchParams(location.search);
  var scenario = "normal";

  // ---------- settings: today's built-in values are the defaults ----------
  var SETTINGS = [
    { key: "theme", title: "Theme", sub: "Light or dark. Follows the phone until you pick one.", def: "System", choices: ["System", "Light", "Dark"] },
    { key: "refresh", title: "Look for a new snapshot", sub: "While the app is in front. It also looks when opened and when you pull down.", def: 30, unit: "seconds", words: ["Every", "seconds"], min: 10, max: 600 },
    { key: "late", title: "Snapshot is late", sub: "Past this age the snapshot gets a warning.", def: 5, words: ["After", "minutes"], min: 1, max: 120 },
    { key: "hot", title: "Busy meters", sub: "A processor, memory or disk meter turns amber above this.", def: 85, words: ["Above", "%"], min: 1, max: 100 },
    { key: "fineShown", title: "Fine services listed", sub: "On a machine, the rest fold under \"and more that are fine\".", def: 8, words: ["Show", "then fold"], min: 1, max: 100 },
    { key: "relayWait", title: "Relay timeout", sub: "How long to wait for the relay before saying it could not be reached.", def: 15, words: ["Wait", "seconds"], min: 5, max: 120 },
    { key: "lock", title: "Ask to unlock", sub: "The phone's own unlock, before anything shows.", def: "Every launch and every return", choices: ["Every launch and every return", "Every launch, and after 1 min away", "Every launch, and after 5 min away"] }
  ];
  var STORE_KEY = "dokkit-android-mock-settings";
  function loadSettings() { return {}; }
  var saved = loadSettings();
  function setting(key) { var d = SETTINGS.find(function (s) { return s.key === key; }); return saved[key] !== undefined ? saved[key] : d.def; }
  function setSetting(key, v) { saved[key] = v; applyLook(); }
  function resetSetting(key) { delete saved[key]; applyLook(); }
  function isChanged(key) { var d = SETTINGS.find(function (s) { return s.key === key; }); return saved[key] !== undefined && String(saved[key]) !== String(d.def); }
  function defaultText(s) { return s.words ? (s.words[0] + " " + s.def + " " + s.words[1]).replace(" %", "%") : s.def; }

  function applyLook() {
    var t = q.get("theme") || setting("theme");
    var root = document.documentElement;
    if (t === "Light" || t === "light") root.dataset.theme = "light";
    else if (t === "Dark" || t === "dark") root.dataset.theme = "dark";
    else delete root.dataset.theme;
  }
  applyLook();

  // ---------- scenarios ----------
  var servers = P.servers.map(function (s) { return { id: s.id, name: s.name, relay: s.relay, added_at: s.added_at, state: { snapshot: s.state.snapshot, made_at: s.state.made_at, problem: null } }; });
  var nw = servers[0];
  var clone = function (o) { return JSON.parse(JSON.stringify(o)); };

  var selectedId = null;
  function selected() { return servers.find(function (s) { return s.id === selectedId; }) || servers[0] || null; }
  function select(id) { selectedId = id; }
  function removeServer(id) { servers = servers.filter(function (s) { return s.id !== id; }); if (selectedId === id) selectedId = null; }

  // ---------- words and times ----------
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  function secondsAgo(iso) { return Math.max(0, Math.round((P.now - new Date(iso)) / 1000)); }
  function ago(iso) {
    var s = secondsAgo(iso);
    return s < 5 ? "just now" : s < 60 ? s + " seconds ago" : s < 3600 ? Math.floor(s / 60) + " min ago" : s < 86400 ? Math.floor(s / 3600) + " h ago" : Math.floor(s / 86400) + " d ago";
  }
  function short(iso) { var d = new Date(iso); return d.toLocaleDateString([], { month: "short", day: "numeric" }) + ", " + d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }); }
  function clock(iso) { return new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" }); }
  function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
  function cap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }

  var LEVEL = {
    ok: { word: "OK", tone: "ok", rank: 0, icon: "check-circle" },
    degraded: { word: "Degraded", tone: "degraded", rank: 2, icon: "hourglass-medium" },
    down: { word: "Down", tone: "down", rank: 3, icon: "warning-octagon" },
    unknown: { word: "No signal yet", tone: "quiet", rank: 1, icon: "circle-dashed" },
    unwatched: { word: "Not watched", tone: "quiet", rank: 0, icon: "eye-slash" },
    soon: { word: "Coming up", tone: "soon", rank: 1, icon: "calendar" },
    snoozed: { word: "Snoozed", tone: "quiet", rank: 1, icon: "moon" }
  };
  function level(s) { return LEVEL[s] || (s ? { word: cap(s), tone: "quiet", rank: 1, icon: "circle" } : LEVEL.unknown); }

  // ---------- freshness (Screens.kt Freshness.make) ----------
  function freshness(state) {
    var lateSec = setting("late") * 60;
    if (!state.snapshot) return { text: "No snapshot yet", warn: !!state.problem, detail: state.problem, tone: state.problem ? "degraded" : "quiet" };
    if (!state.made_at) return { text: "Snapshot age unknown", warn: true, detail: state.problem, tone: "degraded" };
    var stale = secondsAgo(state.made_at) > lateSec;
    var late = stale ? "The server, its network or the relay is not delivering." : null;
    var detail = [state.problem, late].filter(Boolean).join(" ") || null;
    return { text: "Snapshot made " + ago(state.made_at), warn: stale, detail: detail, tone: stale || state.problem ? "degraded" : "quiet" };
  }
  function leftOut(snap) {
    var parts = (snap.server && snap.server.left_out) || [];
    if (!parts.length) return null;
    var names = { logs: "Log lines", issues: "Issue histories", jobs: "Jobs", services: "Service details", chart: "Charts" };
    return parts.map(function (p) { return names[p] || cap(p); }).join(", ") + " were left out of this snapshot to keep it small.";
  }

  // ---------- issues, in Calm in Ember sentences ----------
  function names(snap) { var o = {}; snap.machines.forEach(function (m) { m.services.forEach(function (s) { o[s.id] = s.name; }); }); snap.services.forEach(function (s) { o[s.id] = s.name; }); return o; }
  function issueState(i) { return i.snoozed_until && new Date(i.snoozed_until) > P.now ? "snoozed" : i.soon ? "soon" : i.state; }
  function sentence(i, snap) {
    var svcName = names(snap)[i.service] || "it";
    var where = /^disk/.test(svcName) ? svcName + " on " + i.machine : svcName + " on " + i.machine;
    var st = issueState(i);
    if (st === "snoozed") return "Snoozed until " + new Date(i.snoozed_until).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) + ". It comes back then if it is still wrong.";
    if (st === "soon") return "Nothing is broken. Plan for it when it suits you.";
    if (st === "down") return "Something is wrong with " + where + " since " + ago(i.since) + ".";
    return "Working, but not as it should: " + where + ", since " + ago(i.since) + ".";
  }
  // The phone cannot change anything, so the one next step always opens something on the phone.
  function nextStep(i) {
    if (i.kind === "job") return "See the last run";
    if (i.kind === "threshold" || i.kind === "forecast") return "Look at the disk";
    if (i.kind === "expiry") return "See the certificate";
    return "Look into it";
  }
  function flags(i) {
    var out = [];
    if (i.snoozed_until && new Date(i.snoozed_until) > P.now) out.push({ text: "Snoozed until " + short(i.snoozed_until), tone: "quiet" });
    if (i.acknowledged_at) out.push({ text: "Seen", tone: "ok" });
    if (i.alert && i.alert.status === "held") out.push({ text: "Alert held for the night" + (i.alert.until ? " until " + short(i.alert.until) : ""), tone: "soon" });
    return out;
  }
  function issueLine(i, snap) {
    var parts = [];
    var n = names(snap)[i.service]; if (n) parts.push(n);
    if (i.machine) parts.push(i.machine);
    parts.push("open " + ago(i.since).replace(" ago", ""));
    if (!i.snoozed_until && i.alert && i.alert.status === "held") parts.push("alert held for the night");
    return parts.join(" · ");
  }

  // ---------- home (Home.kt) ----------
  function isProd(env) { return env == null || env === "production"; }
  function meters(v) {
    var hot = setting("hot"), out = [];
    function m(label, val, subject) { return { label: label, subject: subject, percent: Math.round(val), hot: val > hot, fraction: Math.min(100, Math.max(0, val)) / 100 }; }
    if (v["cpu.percent"] != null) out.push(m("CPU", v["cpu.percent"]));
    if (v["memory.used_percent"] != null) out.push(m("Memory", v["memory.used_percent"]));
    var disks = Object.keys(v).filter(function (k) { return k.indexOf("disk.used_percent.") === 0; })
      .sort(function (a, b) { return v[b] - v[a] || (a < b ? -1 : 1); });
    if (disks.length) out.push(m("Disk", v[disks[0]], disks[0].replace("disk.used_percent.", "")));
    return out;
  }
  function card(m) {
    var trouble = [], fine = [], quiet = [];
    m.services.forEach(function (s) {
      if (!isProd(s.environment)) return;
      var row = { id: s.id, name: s.name, state: s.state, level: level(s.state) };
      if (s.state === "ok") fine.push(row); else if (s.state === "unknown" || !s.state) quiet.push(row); else if (s.state !== "unwatched") trouble.push(row);
    });
    var byName = function (a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1; };
    trouble.sort(function (a, b) { return b.level.rank - a.level.rank || byName(a, b); }); fine.sort(byName); quiet.sort(byName);
    var hardware = m.kind === "enrolled", down = hardware && m.down === true;
    var word = !hardware ? null : down ? "Down" : "Up";
    var status = word && (word + (m.last_seen_at ? (down ? " · last reported " : " · ") + ago(m.last_seen_at) : ""));
    var counts = [fine.length ? fine.length + " fine" : null, trouble.length ? trouble.length + " in trouble" : null, quiet.length ? quiet.length + " no signal" : null].filter(Boolean).join(" · ") || "nothing watched";
    var notice = null;
    if (m.planned_downtime) notice = "Planned downtime" + (m.planned_downtime.until ? " until " + short(m.planned_downtime.until) : "");
    else if (m.schedules && m.schedules.length) notice = "Planned downtime scheduled, next " + short(m.schedules[0].next);
    var shown = setting("fineShown");
    return {
      id: m.id, name: m.name, os: m.os, hardware: hardware, down: down, inTrouble: trouble.length > 0,
      mark: down ? "down" : trouble.length ? "degraded" : "ok", word: word, status: status, meters: meters(m.vitals || {}),
      counts: counts, notice: notice, trouble: trouble, fine: fine.slice(0, shown), moreFine: fine.slice(shown),
      quietLine: quiet.length ? quiet.length + " with no signal yet: " + quiet.slice(0, 3).map(function (r) { return r.name; }).join(", ") + (quiet.length > 3 ? "…" : "") : null,
      planned: !!m.planned_downtime, lastDay: hardware ? P.lastDay(m.id) : null
    };
  }
  function home(snap) {
    var cards = snap.machines.map(card);
    var order = function (a, b) { return (b.down - a.down) || (b.inTrouble - a.inTrouble) || (a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1); };
    var needs = snap.inbox.needs_you || [], soon = snap.inbox.soon || [], snoozed = snap.inbox.snoozed || [];
    var top;
    if (needs.length || soon.length) {
      var shown = needs.length ? needs : soon;
      top = { kind: "attention", urgent: needs.length > 0, title: needs.length ? needs.length + " need you" : soon.length + " coming up soon", issues: shown };
    } else {
      var hw = snap.machines.filter(function (m) { return m.kind === "enrolled"; });
      var running = 0; snap.machines.forEach(function (m) { m.services.forEach(function (s) { if (isProd(s.environment) && s.state === "ok") running++; }); });
      var things = plural(running, "thing running", "things running");
      top = { kind: "fine", headline: "Everything is fine", detail: hw.length ? hw.filter(function (m) { return !m.down; }).length + " of " + hw.length + " machines up · " + things : things };
    }
    var lede = needs.length
      ? plural(needs.length, "thing needs", "things need") + " you. " + (soon.length ? plural(soon.length, "is", "are") + " coming up" : "Nothing is coming up") + (snoozed.length ? ", and " + snoozed.length + " is snoozed." : ".")
      : soon.length ? "Nothing needs you. " + plural(soon.length, "thing is", "things are") + " coming up when it suits you."
      : "Nothing needs you right now. Dokkit keeps watching.";
    var fine = snap.inbox.fine;
    return {
      top: top, needs: needs, soon: soon, snoozedList: snoozed, snoozed: snoozed.length ? snoozed.length + " snoozed" : null, lede: lede,
      fineLine: fine && fine.services ? "Everything else is fine: " + fine.services + " services on " + fine.machines + " machines." : null,
      hardware: cards.filter(function (c) { return c.hardware; }).sort(order), groups: cards.filter(function (c) { return !c.hardware; }).sort(order)
    };
  }
  function greeting() { var h = new Date(P.now).getHours(); return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"; }

  // ---------- service (Screens.kt service) ----------
  function service(snap, id) {
    var all = snap.services.concat(snap.machines.reduce(function (a, m) { return a.concat(m.services); }, []));
    var s = all.find(function (x) { return x.id === id; });
    if (!s) return null;
    var open = s.open_issue || snap.issues.find(function (i) { return i.service === id && !i.closed_at; }) || null;
    var job = snap.jobs.find(function (j) { return j.id === id; });
    var jobLines = [];
    if (job) {
      if (job.schedule) jobLines.push(["Schedule", job.schedule]);
      if (job.last_run) {
        var r = job.last_run, v = r.result || "unknown";
        if (r.exit_code != null) v += ", exit code " + r.exit_code;
        if (r.duration_ms != null) v += ", took " + Math.round(r.duration_ms / 1000) + " s";
        if (r.result === "running" && r.total) v += ", " + Math.floor(r.done / r.total * 100) + " percent";
        jobLines.push(["Last run", v]);
        if (r.started_at) jobLines.push(["Started", short(r.started_at)]);
      }
      if (job.last_good_run) jobLines.push(["Last good run", short(job.last_good_run)]);
      if (job.next_expected) jobLines.push(["Next expected", short(job.next_expected)]);
    }
    return {
      id: id, name: s.name, machine: s.machine, kind: s.kind, state: s.state, level: level(s.state), version: s.version, environment: s.environment, note: s.note,
      checks: (s.checks || []).filter(function (c) { return c.state !== "unwatched"; }).map(function (c) { return { name: c.name, kind: c.type, state: c.state, level: level(c.state), note: c.note, checked: c.checked_at ? ago(c.checked_at) : null }; }),
      issue: open, history: (open && open.history || []).map(function (e) {
        var t = cap(e.event || "event");
        if (e.event === "snoozed" && e.until) t += " until " + short(e.until);
        if (e.note) t += ": " + e.note;
        if (e.by) t += " (" + e.by + ")";
        return { when: e.at ? short(e.at) : null, ago: e.at ? ago(e.at) : null, text: t };
      }),
      chart: (s.chart && s.chart.values) || [], metric: s.chart && s.chart.metric, job: jobLines, jobRaw: job || null,
      logs: (snap.logs[id] || []).map(function (l) { return { time: l.t ? clock(l.t) : "--:--:--", level: l.level || "info", msg: l.msg || "", error: l.level === "error" }; })
    };
  }
  function machineById(snap, id) { return snap.machines.find(function (m) { return m.id === id; }); }

  // ---------- pairing (Pairing.kt messages) ----------
  var PAIR_ERRORS = {
    notacode: "This is not a Dokkit pairing code.",
    damaged: "The pairing code is damaged. Show a new one in Settings, Phones.",
    https: "The relay address in this code is not https, so the app refuses it."
  };

  return {
    P: P, scenario: scenario, servers: function () { return servers; }, selected: selected, select: select, removeServer: removeServer,
    esc: esc, ago: ago, short: short, clock: clock, plural: plural, cap: cap, level: level, LEVEL: LEVEL,
    freshness: freshness, leftOut: leftOut, home: home, card: card, service: service, machineById: machineById, greeting: greeting,
    sentence: sentence, nextStep: nextStep, flags: flags, issueLine: issueLine, issueState: issueState, names: names,
    SETTINGS: SETTINGS, setting: setting, setSetting: setSetting, resetSetting: resetSetting, isChanged: isChanged, defaultText: defaultText,
    PAIR_ERRORS: PAIR_ERRORS, host: function (url) { try { return new URL(url).host; } catch (e) { return url; } },
    reduced: q.get("still") === "1" || matchMedia("(prefers-reduced-motion: reduce)").matches
  };
})();

// Pieces every direction can use as they are or restyle: the phone chrome, small parts, and the screens
// whose content is the same everywhere (lock, first run, add a server, servers, settings).
window.UI = (function () {
  var C = window.CORE, esc = C.esc, P = C.P;

  function icon(name) { return '<i class="ph ph-' + name + '" aria-hidden="true"><svg><use href="#i-' + name + '"/></svg></i>'; }
  function ic(tone, name, size) { return '<span class="ic ' + (size || "") + " t-" + tone + '" aria-hidden="true">' + icon(name) + "</span>"; }
  function tag(tone, text) { return '<span class="tag t-' + tone + '">' + esc(text) + "</span>"; }

  function statusbar() {
    var t = new Date(P.now).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    return '<div class="statusbar" aria-hidden="true"><span>' + t + '</span><span class="icons">' + icon("wifi-high") + icon("cell-signal-full") + icon("battery-high") + "</span></div>";
  }
  // A phone: status bar, a scrolling screen, optional fixed bits around it, the gesture bar.
  function phone(o) {
    return '<div class="phone">' + statusbar() + (o.top || "") + '<main class="screen" id="screen" tabindex="-1">' + (o.body || "") + "</main>" + (o.bottom || "") + '<div class="gesture" aria-hidden="true"></div>' +
      '<div class="toast" id="toast" role="status" aria-live="polite"></div><div id="layer"></div></div>';
  }

  // ---------- small parts ----------
  function strip(id, small) {
    var cells = P.lastDay(id);
    return '<div class="strip' + (small ? " sm" : "") + '" role="img" aria-label="' + esc(id) + ', the last day">' + cells.map(function (c) { return '<i class="' + c + '"></i>'; }).join("") + "</div>";
  }
  function legend() { return '<div class="legend"><span><b></b>Fine</span><span><b class="warn"></b>Slow</span><span><b class="bad"></b>Down</span><span><b class="off"></b>Not expected</span></div>'; }
  function meter(m) {
    return '<div class="m"><div class="m-top"><span>' + esc(m.label) + (m.subject ? ' <span class="mono">' + esc(m.subject) + "</span>" : "") + '</span><b class="' + (m.hot ? "hot" : "") + '">' + m.percent + '%</b></div>' +
      '<div class="meter" role="meter" aria-label="' + esc(m.label) + '" aria-valuenow="' + m.percent + '" aria-valuemin="0" aria-valuemax="100"><b class="' + (m.hot ? "hot" : "") + '" style="width:' + m.percent + '%"></b></div></div>';
  }
  function ageBanner(f) {
    if (!f.warn && !f.detail) return '<p class="age sub">' + icon("clock") + " " + esc(f.text) + "</p>";
    return '<div class="banner t-' + f.tone + '" role="status">' + icon(f.warn ? "warning" : "info") + "<div><p><b>" + esc(f.text) + "</b></p>" + (f.detail ? "<p>" + esc(f.detail) + "</p>" : "") + "</div></div>";
  }
  function issueCard(i, snap, href) {
    var st = C.issueState(i), lv = st === "soon" ? C.LEVEL.soon : st === "snoozed" ? C.LEVEL.snoozed : C.level(st);
    var fl = C.flags(i);
    return '<article class="issue ' + st + '">' + ic(lv.tone, lv.icon) +
      "<div><h3>" + esc(i.title) + '</h3><p class="say">' + esc(C.sentence(i, snap)) + "</p></div>" +
      '<p class="meta"><span>' + esc(i.machine) + "</span><span>" + esc(i.short_id) + "</span>" + (i.count > 1 ? "<span>" + i.count + " times</span>" : "") + "</p>" +
      (fl.length ? '<div class="flags">' + fl.map(function (f) { return tag(f.tone, f.text); }).join("") + "</div>" : "") +
      '<div class="act"><a class="btn soft" href="' + href + '">' + esc(C.nextStep(i)) + " " + icon("arrow-right") + "</a></div></article>";
  }
  function chart(values, label) {
    var present = values.filter(function (v) { return v != null; });
    if (!present.length) return "";
    var hi = Math.max.apply(null, present) || 1;
    return '<div class="spark" role="img" aria-label="' + esc(label || "Chart") + ' over the last 24 hours, latest ' + Math.round(present[present.length - 1]) + '">' +
      values.map(function (v) { return v == null ? "<i></i>" : '<i style="height:' + Math.max(6, v / hi * 100) + '%"></i>'; }).join("") + "</div>";
  }
  function logLines(lines) {
    return '<div class="loglines">' + lines.map(function (l) {
      return '<div class="' + (l.level === "error" ? "error" : l.level === "warn" ? "warn" : "") + '"><span class="t">' + esc(l.time) + "</span><span>" + esc(l.level.toUpperCase().slice(0, 5)) + "</span><span>" + esc(l.msg) + "</span></div>";
    }).join("") + "</div>";
  }

  // ---------- layer: toast, dialog, sheet ----------
  var toastTimer;
  function toast(msg) {
    var t = document.getElementById("toast"); if (!t) return;
    t.textContent = msg; t.classList.add("show");
    clearTimeout(toastTimer); toastTimer = setTimeout(function () { t.classList.remove("show"); }, 2400);
  }
  function closeLayer() {
    var l = document.getElementById("layer"); if (!l) return;
    l.querySelectorAll(".show").forEach(function (e) { e.classList.remove("show"); });
    setTimeout(function () { l.innerHTML = ""; }, C.reduced ? 0 : 220);
  }
  function openLayer(html, kind) {
    var l = document.getElementById("layer");
    l.innerHTML = '<div class="scrim" data-close></div>' + (kind === "sheet" ? '<section class="sheet" role="dialog" aria-modal="true"><div class="grab"></div>' + html + "</section>" : '<section class="dialog" role="alertdialog" aria-modal="true">' + html + "</section>");
    requestAnimationFrame(function () { l.querySelectorAll(".scrim, .sheet, .dialog").forEach(function (e) { e.classList.add("show"); }); });
  }
  document.addEventListener("click", function (e) { if (e.target.closest("[data-close]")) closeLayer(); });
  function confirmRemove(server, onYes) {
    openLayer("<h2>Remove " + esc(server.name) + " from this phone?</h2><p>Its key, its token and its saved snapshot are deleted from this phone. Nothing changes on the server.</p>" +
      '<div class="row"><button class="btn ghost" type="button" data-close>Cancel</button><button class="btn danger" type="button" id="yes-remove">Remove</button></div>');
    setTimeout(function () { var b = document.getElementById("yes-remove"); if (b) b.onclick = function () { closeLayer(); onYes(); }; }, 0);
  }

  // ---------- screens whose content is the same everywhere ----------
  var LOGO = '<svg viewBox="0 0 100 100" fill="currentColor" aria-hidden="true"><circle cx="27.5" cy="30.5" r="5.4"></circle><path d="M39 25H53A23 23 0 0 1 53 71H28A4 4 0 0 1 24 67V43A4 4 0 0 1 28 39H33A4 4 0 0 1 37 43V60H53A12 12 0 0 0 53 36H39A3.5 3.5 0 0 1 35.5 32.5V28.5A3.5 3.5 0 0 1 39 25Z"></path></svg>';
  function mark(size) { return '<span class="mark" style="width:' + size + "px;height:" + size + "px;border-radius:" + Math.round(size * .28) + 'px;background:var(--brand);color:var(--brand-ink);display:grid;place-items:center">' + LOGO.replace("<svg ", '<svg style="width:' + Math.round(size * .82) + "px;height:" + Math.round(size * .82) + 'px" ') + "</span>"; }

  function lockScreen() {
    var msg = C.scenario === "nolock" ? "Set a screen lock on this phone to use Dokkit." : C.scenario === "stayed" ? "Dokkit stayed locked." : null;
    return '<div class="center-screen settle">' + ic("brand", "lock-simple", "lg") + '<h1 class="title" style="font-size:26px">Dokkit is locked</h1>' +
      '<p class="lede">' + (msg ? esc(msg) : "Unlock with your fingerprint, face or screen lock.") + "</p>" +
      '<button class="btn primary block" type="button" data-go="#home">' + icon("fingerprint") + " Unlock</button></div>";
  }
  function firstRun() {
    return '<div class="center-screen settle">' + mark(88) + '<h1 class="title">Dokkit</h1>' +
      '<p class="lede">A read-only view of your Dokkit server.<br>Alerts still reach you the usual way.<br>Nothing here can change anything.</p>' +
      '<p class="sub">The code is in the Dokkit web interface: Settings, Phones, Add a phone.</p>' +
      '<a class="btn primary block" href="#add">' + icon("qr-code") + " Scan the code</a>" +
      '<a class="btn ghost block" href="#add/paste">Paste the code instead</a></div>';
  }
  function addServer(mode) {
    var paste = mode === "paste", camOff = C.scenario === "camoff", err = C.scenario === "pairerr" ? C.PAIR_ERRORS.damaged : null;
    return '<div class="pad-screen settle"><p class="lede">' + (paste ? "Paste the code from the Dokkit web interface, under Settings, Phones, Add a phone."
      : "Scan the QR code in the Dokkit web interface under Settings, Phones, Add a phone. It is shown once.") + "</p>" +
      (paste ? "" : camOff
        ? '<div class="panel pad" style="text-align:center;display:grid;justify-items:center">' + ic("quiet", "camera-slash") + '<p class="h2" style="margin-top:10px">The camera is off</p><p class="sub">Allow the camera to scan, or paste the code below.</p><button class="btn" type="button" style="margin-top:12px" data-toast="Android asks for the camera here.">Allow the camera</button></div>'
        : '<div class="camera" role="img" aria-label="Camera view for scanning the QR code"><span class="aim"></span><span class="hint">Point it at the code</span></div>') +
      (err ? '<div class="banner t-degraded" role="alert">' + icon("warning") + "<p>" + esc(err) + "</p></div>" : "") +
      '<label class="h2" for="code" style="font-size:15px">Or paste the code</label><textarea class="field" id="code" placeholder="dokkit-phone:1:..." autocapitalize="off" spellcheck="false"></textarea>' +
      '<button class="btn" type="button" id="add-btn" disabled>Add</button></div>';
  }
  function serverRow(s, current) {
    var f = C.freshness(s.state);
    return '<div class="srv"><button class="srv-main" type="button" data-show="' + s.id + '"><span class="srv-name">' + esc(s.name) + (current ? " " + tag("brand", "Showing") : "") + "</span>" +
      '<span class="sub mono">' + esc(C.host(s.relay)) + '</span><span class="sub' + (f.warn ? " warn" : "") + '">' + esc(f.text) + "</span>" + (f.detail ? '<span class="sub warn">' + esc(f.detail) + "</span>" : "") + "</button>" +
      '<button class="iconbtn danger" type="button" data-remove="' + s.id + '" aria-label="Remove ' + esc(s.name) + '">' + icon("trash") + "</button></div>";
  }
  function serversList() {
    var list = C.servers(), cur = C.selected();
    if (!list.length) return '<div class="panel pad" style="text-align:center;display:grid;justify-items:center">' + ic("quiet", "device-mobile") + '<p class="h2" style="margin-top:10px">No server paired</p><p class="sub">In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Choose Add a server below and scan it.</p></div>' +
      '<a class="btn primary block" href="#add">' + icon("plus") + " Add a server</a>";
    return '<section class="panel"><div class="panel-head"><span class="h2">Paired servers</span><span class="sub">' + list.length + "</span></div>" +
      list.map(function (s) { return serverRow(s, cur && s.id === cur.id); }).join("") + "</section>" +
      '<a class="btn primary block" href="#add">' + icon("plus") + " Add a server</a>";
  }
  function settingRow(s) {
    var v = C.setting(s.key), changed = C.isChanged(s.key), ctl;
    if (s.choices) ctl = '<select data-set="' + s.key + '" aria-label="' + esc(s.title) + '">' + s.choices.map(function (c) { return "<option" + (c === v ? " selected" : "") + ">" + esc(c) + "</option>"; }).join("") + "</select>";
    else ctl = "<span>" + esc(s.words[0]) + '</span><input type="number" inputmode="numeric" data-set="' + s.key + '" value="' + v + '" min="' + s.min + '" max="' + s.max + '" aria-label="' + esc(s.title) + '"><span>' + esc(s.words[1]) + "</span>";
    return '<div class="cfg-row' + (changed ? " changed" : "") + '"><div><h3>' + esc(s.title) + '</h3><p class="sub">' + esc(s.sub) + '</p></div><div class="ctl">' + ctl + "</div>" +
      '<span class="def">Default: ' + esc(C.defaultText(s)) + (changed ? '<button type="button" data-reset="' + s.key + '">Reset</button>' : "") + "</span></div>";
  }
  function settingsGroups() {
    var groups = [
      ["set-look", "palette", "Look", "Theme and accent.", ["theme", "accent"]],
      ["set-fresh", "arrows-clockwise", "Snapshots", "How often the app looks, and when it warns.", ["refresh", "late", "relayWait"]],
      ["set-show", "squares-four", "What the screens show", "Meters and long lists.", ["hot", "fineShown"]],
      ["set-lock", "lock-simple", "Unlock", "When the app asks again.", ["lock"]]
    ];
    return groups.map(function (g, n) {
      return '<details class="panel fold" id="' + g[0] + '"' + (n === 0 ? " open" : "") + "><summary>" + ic("brand", g[1], "sm") + '<div><span class="h2">' + g[2] + '</span><p class="sub">' + g[3] + "</p></div>" + icon("caret-down").replace('class="ph', 'class="chev ph') + "</summary>" +
        '<div class="fold-body">' + g[4].map(function (k) { return settingRow(C.SETTINGS.find(function (s) { return s.key === k; })); }).join("") +
        '<div class="save-row"><p class="sub">Applies on this phone only.</p><button class="btn primary" type="button" data-save>' + icon("check") + " Save</button></div></div></details>";
    }).join("");
  }
  function about() {
    return '<section class="panel pad stack" style="gap:6px"><span class="h2">About</span><p class="sub">Dokkit for Android 0.1.0. Read-only: it cannot change anything on a server and sends no notifications. It fetches when opened, when you pull down, and on the schedule above while in front.</p></section>';
  }

  // Wires the shared screens' controls; call after each render.
  function wire(rerender) {
    var code = document.getElementById("code"), add = document.getElementById("add-btn");
    if (code && add) {
      code.oninput = function () { add.disabled = !code.value.trim(); };
      add.onclick = function () {
        var v = code.value.trim();
        if (v.indexOf("dokkit-phone:") !== 0) { toast(C.PAIR_ERRORS.notacode); return; }
        toast("Paired. Fetching the first snapshot…"); setTimeout(function () { window.DEMO.go("#home"); }, 900);
      };
    }
    document.querySelectorAll("[data-show]").forEach(function (b) { b.onclick = function () { C.select(b.dataset.show); toast("Showing " + C.selected().name + "."); rerender(); }; });
    document.querySelectorAll("[data-remove]").forEach(function (b) {
      b.onclick = function () { var s = C.servers().find(function (x) { return x.id === b.dataset.remove; }); confirmRemove(s, function () { C.removeServer(s.id); toast("Removed " + s.name + " from this phone."); rerender(); }); };
    });
    document.querySelectorAll("[data-set]").forEach(function (el) {
      el.onchange = function () { C.setSetting(el.dataset.set, el.type === "number" ? +el.value : el.value); rerender(true); };
    });
    document.querySelectorAll("[data-reset]").forEach(function (b) { b.onclick = function () { C.resetSetting(b.dataset.reset); toast("Back to the default."); rerender(true); }; });
    document.querySelectorAll("[data-save]").forEach(function (b) { b.onclick = function () { var n = C.SETTINGS.filter(function (s) { return C.isChanged(s.key); }).length; toast(n ? "Saved. " + C.plural(n, "setting differs", "settings differ") + " from the default." : "Saved. Everything is on its default."); }; });
    document.querySelectorAll("[data-toast]").forEach(function (b) { b.onclick = function () { toast(b.dataset.toast); }; });
    document.querySelectorAll("[data-go]").forEach(function (b) { b.onclick = function () { window.DEMO.go(b.dataset.go); }; });
  }

  // Pull to refresh and the refresh button share one fake fetch.
  function fakeRefresh(done) { toast("Looking for a new snapshot…"); setTimeout(function () { toast("Up to date. Snapshot made just now."); if (done) done(); }, 900); }

  // Where the app starts for the scenario chosen on the review page.
  function startRoute() {
    if (C.scenario === "locked" || C.scenario === "nolock" || C.scenario === "stayed") return "#lock";
    if (C.scenario === "none") return "#first";
    if (C.scenario === "camoff" || C.scenario === "pairerr") return "#add";
    return "#home";
  }

  return { icon: icon, ic: ic, tag: tag, phone: phone, strip: strip, legend: legend, meter: meter, ageBanner: ageBanner, issueCard: issueCard, chart: chart, logLines: logLines,
    toast: toast, openLayer: openLayer, closeLayer: closeLayer, confirmRemove: confirmRemove, mark: mark, lockScreen: lockScreen, firstRun: firstRun, addServer: addServer,
    serversList: serversList, serverRow: serverRow, settingsGroups: settingsGroups, settingRow: settingRow, about: about, wire: wire, fakeRefresh: fakeRefresh, startRoute: startRoute };
})();

// Dokkit on the iPhone Duo: direction J (Statement) as the iOS app has it now. Folded it is the phone app;
// open it is two panes split at the crease. ?d=k|l|m picks what the right pane holds and where the tab bar sits.
(function () {
  var C = window.CORE, U = window.UI, esc = C.esc, icon = U.icon;
  var DIR = "l";
  var REDUCED = C.reduced;
  var TABS = [["home", "Home", "house"], ["servers", "Servers", "hard-drives"], ["settings", "Settings", "gear"]];
  var GROUPS = [
    ["look", "palette", "Look", "Theme.", ["theme"]],
    ["snapshots", "arrows-clockwise", "Snapshots", "How often the app looks, and when it warns.", ["refresh", "late", "relayWait"]],
    ["show", "squares-four", "What the screens show", "Meters and long lists.", ["hot", "fineShown"]],
    ["unlock", "lock-simple", "Unlock", "When the app asks again.", ["lock"]]
  ];
  var openMachines = {}, openMore = {}, issueTab = null, seen = {};

  // ---------- springs: the measured iOS 27 lens ----------
  function spring(response, ratio) { var k = Math.pow(2 * Math.PI / response, 2); return { k: k, c: 2 * ratio * Math.sqrt(k) }; }
  var TRAVEL = spring(0.4, 0.85), LIFT = spring(0.25, 1), SETTLE = { k: 320, c: 2 * 0.42 * Math.sqrt(320) }, SWELL = spring(0.3, 0.6), LEAN_IN = spring(0.13, 1);
  function Sp(x, p) { return { x: x, v: 0, t: x, k: p.k, c: p.c }; }
  function aim(s, t, p) { s.t = t; if (p) { s.k = p.k; s.c = p.c; } }
  function stepAll(list, dt) {
    var moving = false, n = Math.ceil(dt / 0.004), h = dt / n;
    list.forEach(function (s) {
      for (var i = 0; i < n; i++) { var a = -s.k * (s.x - s.t) - s.c * s.v; s.v += a * h; s.x += s.v * h; }
      if (Math.abs(s.x - s.t) < 0.0005 && Math.abs(s.v) < 0.002) { s.x = s.t; s.v = 0; } else moving = true;
    });
    return moving;
  }
  // Runs one value from 0 to 1 on the travel spring.
  function run01(onFrame, onDone, p) {
    var s = Sp(0, p || TRAVEL); s.t = 1;
    if (REDUCED) { onFrame(1); if (onDone) onDone(); return; }
    var last = performance.now();
    (function frame(now) {
      var dt = Math.min(0.05, (now - last) / 1000); last = now;
      var moving = stepAll([s], dt);
      onFrame(s.x);
      if (moving) requestAnimationFrame(frame); else if (onDone) onDone();
    })(last);
  }

  // ---------- the glass selector ----------
  function Glass(o) {
    var el = document.createElement("div");
    el.className = "gl " + (o.cls || "") + (o.vertical ? " vertical" : "");
    el.setAttribute("role", "tablist");
    el.innerHTML = '<span class="gl-bg"></span><span class="gl-rest"></span><div class="gl-items">' +
      o.items.map(function (it, i) { return '<button class="gl-item" type="button" role="tab" data-i="' + i + '"><span>' + it + "</span></button>"; }).join("") +
      '</div><span class="gl-glass"></span>';
    var rest = el.querySelector(".gl-rest"), glass = el.querySelector(".gl-glass"), btns = el.querySelectorAll(".gl-item");
    var inset = o.inset == null ? 4 : o.inset, count = o.items.length;
    var pos = Sp(o.selected || 0, TRAVEL), lift = Sp(0, LIFT), lean = Sp(0, LEAN_IN), squash = Sp(0, SETTLE), swell = Sp(0, SWELL);
    var springs = [pos, lift, lean, squash, swell], under = o.selected || 0, selected = under, raf = 0, timers = [], dragging = false, last = 0;

    function size() { return o.vertical ? el.clientHeight : el.clientWidth; }
    function cross() { return o.vertical ? el.clientWidth : el.clientHeight; }
    function unit() { return (size() - 2 * inset) / count; }
    function draw() {
      var u = unit(), L = u + 16 * lift.x, T = cross() - 2 * inset + 16 * lift.x;
      var c = inset + (pos.x + 0.5) * u, mid = cross() / 2;
      var w = o.vertical ? T : L, h = o.vertical ? L : T, x = o.vertical ? mid - T / 2 : c - L / 2, y = o.vertical ? c - L / 2 : mid - T / 2;
      var along = 1 + 0.12 * lean.x - squash.x, across = 1 - 0.16 * lean.x + squash.x * 0.6;
      var sx = o.vertical ? across : along, sy = o.vertical ? along : across;
      [rest, glass].forEach(function (e) { e.style.width = w + "px"; e.style.height = h + "px"; e.style.transform = "translate(" + x + "px," + y + "px) scale(" + sx + "," + sy + ")"; });
      rest.style.opacity = String(1 - lift.x);
      glass.style.opacity = String(0.6 + 0.4 * lift.x);
      el.style.transform = swell.x ? "scale(" + (1 + swell.x * 0.025) + ")" : "";
      btns.forEach(function (b, i) { b.firstChild.style.transform = i === under ? "scale(" + (1 + 0.16 * lift.x) + ")" : ""; b.classList.toggle("on", i === under); b.setAttribute("aria-selected", String(i === selected)); });
      if (o.onPos) o.onPos(pos.x);
    }
    function loop() {
      if (raf) return;
      last = performance.now();
      raf = requestAnimationFrame(function frame(now) {
        var dt = Math.min(0.05, (now - last) / 1000); last = now;
        var moving = stepAll(springs, dt); draw();
        raf = moving ? requestAnimationFrame(frame) : 0;
      });
    }
    function later(ms, fn) { timers.push(setTimeout(fn, ms)); }
    function land(distance) {
      aim(lift, 0, LIFT);
      if (distance >= 8) { squash.x = 0.04 + 0.11 * Math.min(1, Math.max(0, (distance - 64) / 194)); squash.v = 0; aim(squash, 0, SETTLE); }
      loop();
    }
    function move(i, animate) {
      timers.forEach(clearTimeout); timers = [];
      var distance = Math.abs(i - pos.x) * unit();
      under = selected = i;
      if (!animate || REDUCED) { springs.forEach(function (s) { s.v = 0; }); pos.x = pos.t = i; lift.x = lift.t = 0; lean.x = lean.t = 0; squash.x = squash.t = 0; swell.x = swell.t = 0; draw(); return; }
      aim(pos, i, TRAVEL);
      if (distance > 1) {
        aim(lift, 1, LIFT); aim(lean, 1, LEAN_IN); aim(swell, 1, LEAN_IN);
        later(130, function () { aim(lean, 0, TRAVEL); aim(swell, 0, SWELL); loop(); });
        // About a quarter second in the lens is within a few points of its target; that is when it lands.
        later(270, function () { land(distance); });
      }
      loop();
    }
    el.addEventListener("click", function (e) {
      var b = e.target.closest(".gl-item"); if (!b || el.dataset.dragged) return;
      var i = +b.dataset.i; if (i === selected) return;
      move(i, true); o.onSelect(i);
    });
    // Press and drag lifts the lens under the finger; letting go picks what is under it.
    var startAt = null;
    el.addEventListener("pointerdown", function (e) { startAt = o.vertical ? e.clientY : e.clientX; delete el.dataset.dragged; });
    window.addEventListener("pointermove", function (e) {
      if (startAt == null) return;
      var p = o.vertical ? e.clientY : e.clientX;
      if (!dragging && Math.abs(p - startAt) < 8) return;
      if (!dragging) { dragging = true; el.dataset.dragged = "1"; aim(lift, 1, LIFT); }
      var r = el.getBoundingClientRect(), local = (p - (o.vertical ? r.top : r.left)) / (o.vertical ? r.height / el.clientHeight : r.width / el.clientWidth);
      var x = Math.min(count - 1, Math.max(0, (local - inset) / unit() - 0.5));
      aim(pos, x, spring(0.18, 0.9)); under = Math.round(x); loop();
    });
    window.addEventListener("pointerup", function () {
      if (startAt == null) return; startAt = null;
      if (!dragging) return;
      dragging = false;
      var i = Math.round(pos.t);
      aim(pos, i, TRAVEL); land(unit() * 0.5); under = i;
      if (i !== selected) { selected = i; o.onSelect(i); }
      setTimeout(function () { delete el.dataset.dragged; }, 0);
    });
    requestAnimationFrame(draw);
    el.glass = { select: move, redraw: draw, get selected() { return selected; } };
    return el;
  }

  // ---------- routes ----------
  var here = "#home";
  function route() {
    var h = here;
    var parts = h.slice(1).split("/");
    return { name: parts[0] || "home", id: parts.slice(1).join("/"), hash: h };
  }
  function tabOf(r) { return r.name === "servers" || r.name === "add" ? 1 : r.name === "settings" ? 2 : r.name === "lock" || r.name === "first" ? -1 : 0; }
  function isOpen() { return window.innerWidth >= 800 && window.innerWidth > window.innerHeight; }
  function noServers() { return !C.servers().length; }

  // ---------- pieces (from J, in Figtree, with capsule runs) ----------
  function hero(o) {
    return '<div class="j-pin"><section class="j-hero j-tone-' + o.tone + '">' +
      '<div class="j-fold"><div class="j-hrow"><span class="j-hic" aria-hidden="true">' + icon(o.icon) + '</span><p class="j-eye">' + (o.eye || "") + "</p></div></div>" +
      '<h2 class="j-big">' + o.big + "</h2>" +
      '<div class="j-fold">' + (o.lede ? '<p class="j-lede">' + o.lede + "</p>" : "") + (o.extra || "") + (o.age ? '<p class="j-age">' + icon("clock") + " " + esc(o.age) + "</p>" : "") + "</div>" +
      "</section></div>";
  }
  function num(n, key) { return '<span class="j-num" data-to="' + n + '" data-key="' + esc(key) + '">' + n + "</span>"; }
  function figure(n, word, tone, key) { return '<div class="j-fig ' + (n ? tone : "") + '"><b>' + num(n, key) + "</b><span>" + esc(word) + "</span></div>"; }
  function card(inner, cls) { return '<section class="j-card j-rise ' + (cls || "") + '">' + inner + "</section>"; }
  function ageLine(f) { return f && !f.warn && !f.detail ? f.text : null; }
  function pipTone(mark) { return mark === "down" ? "down" : mark === "degraded" ? "degraded" : ""; }
  function caps(id, big, row) {
    var cells = C.P.lastDay(id), runs = [];
    cells.forEach(function (c) { var k = c === "none" ? "off" : c; if (runs.length && runs[runs.length - 1].k === k) runs[runs.length - 1].n++; else runs.push({ k: k, n: 1 }); });
    return '<div class="cap' + (big ? " lg" : "") + '" data-cap="' + esc(id) + '" style="--row:' + (row || 0) + '" role="img" aria-label="' + esc(id) + ', the last day">' +
      runs.map(function (r) { return '<i class="' + r.k + '" style="flex:' + r.n + ' 1 0"></i>'; }).join("") + "</div>";
  }
  function svcRow(r) {
    return '<a class="j-svc" href="#service/' + esc(r.id) + '"><span class="pip ' + (r.level.tone === "ok" ? "" : r.level.tone) + '" aria-hidden="true"></span><span class="name">' + esc(r.name) + '</span><span class="what t-' + r.level.tone + '">' + esc(r.level.word) + "</span></a>";
  }
  function services(c) {
    var more = openMore[c.id], out = "";
    if (!c.trouble.length && !c.fine.length && !c.moreFine.length && !c.quietLine) out += '<p class="sub j-line">Nothing is watched on it.</p>';
    out += c.trouble.map(svcRow).join("") + c.fine.map(svcRow).join("") + (more ? c.moreFine.map(svcRow).join("") : "");
    if (c.moreFine.length) out += '<button class="j-more" type="button" data-more="' + esc(c.id) + '">' + (more ? "Show fewer" : "and " + c.moreFine.length + " more that are fine") + "</button>";
    if (c.quietLine) out += '<p class="sub j-line">' + icon("circle-dashed") + " " + esc(c.quietLine) + "</p>";
    return out;
  }
  function machineRow(c) {
    var open = !!openMachines[c.id];
    return '<section class="j-mrow' + (open ? " open" : "") + '">' +
      '<button class="j-mhead" type="button" data-machine="' + esc(c.id) + '" aria-expanded="' + open + '">' +
      (c.hardware ? '<span class="pip ' + (c.planned ? "quiet" : pipTone(c.mark)) + '" aria-hidden="true"></span>' : '<span class="j-gicon" aria-hidden="true">' + icon("cloud") + "</span>") +
      '<span class="j-mtext"><span class="j-mname">' + esc(c.name) + "</span>" +
      (c.status ? '<span class="sub' + (c.down ? " j-down" : "") + '">' + esc(c.status) + "</span>" : "") +
      '<span class="sub">' + esc(c.counts) + "</span></span>" + icon("caret-down").replace('class="ph', 'class="chev ph') + "</button>" +
      (open ? '<div class="j-mbody">' +
        (c.meters.length ? '<div class="j-meters">' + c.meters.map(U.meter).join("") + "</div>" : "") +
        (c.notice ? '<p class="j-notice t-quiet">' + icon("moon") + " " + esc(c.notice) + "</p>" : "") +
        '<div class="j-svcs">' + services(c) + "</div>" +
        (c.hardware ? '<a class="btn soft block" href="#machine/' + esc(c.id) + '">Open ' + esc(c.name) + " " + icon("arrow-right") + "</a>" : "") +
        "</div>" : "") +
      "</section>";
  }
  function noSnapshot(f, title) {
    return { title: title || "Home", tools: true, tone: "quiet", top: hero({ tone: "quiet", icon: "hourglass-medium", eye: esc(C.greeting()), big: "No snapshot yet",
      lede: "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again." }),
      body: f && f.detail ? U.ageBanner(f) : "" };
  }

  // ---------- home, in parts so it can spread across the book ----------
  function homeParts() {
    var s = C.selected(), st = s.state, f = C.freshness(st), snap = st.snapshot;
    if (!snap) return { empty: noSnapshot(f) };
    var h = C.home(snap), top = h.top;
    var tone = top.kind === "fine" ? "ok" : top.urgent ? (h.needs.some(function (i) { return i.state === "down"; }) ? "down" : "degraded") : "soon";
    var icn = { down: "warning-octagon", degraded: "hourglass-medium", soon: "calendar", ok: "check-circle" }[tone];
    var big = top.kind === "fine" ? esc(top.headline)
      : h.needs.length ? num(h.needs.length, "hero-needs") + " " + (h.needs.length === 1 ? "thing needs you" : "things need you")
      : num(h.soon.length, "hero-soon") + " " + (h.soon.length === 1 ? "thing is coming up" : "things are coming up");
    var lede = top.kind === "fine" ? top.detail : h.needs.length ? h.lede.replace(/^[^.]*\.\s*/, "") : "Nothing needs you. Plan for " + (h.soon.length === 1 ? "it" : "them") + " when it suits you.";

    var a = "";
    if (f.warn || f.detail) a += U.ageBanner(f);
    var lo = C.leftOut(snap); if (lo) a += '<p class="sub j-left">' + icon("info") + " " + esc(lo) + "</p>";
    var fine = snap.inbox.fine && snap.inbox.fine.services || 0;
    a += card('<div class="j-figs">' + figure(h.needs.length, "need you", tone === "down" ? "down" : "degraded", "fig-needs") + figure(h.soon.length, "coming up", "soon", "fig-soon") + figure(fine, "fine", "ok", "fig-fine") + "</div>");
    if (top.kind === "attention") {
      var both = h.needs.length && h.soon.length;
      if (!issueTab || (issueTab === "needs" && !h.needs.length) || (issueTab === "soon" && !h.soon.length)) issueTab = h.needs.length ? "needs" : "soon";
      var lane = function (list, key) { return '<div class="d-lane" data-lane="' + key + '">' + list.map(function (i) { return '<div data-morph="' + esc(i.service) + '">' + U.issueCard(i, snap, "#service/" + i.service) + "</div>"; }).join("") + "</div>"; };
      if (both) a += '<div data-seg="' + h.needs.length + "/" + h.soon.length + '"></div><div class="d-clip"><div class="d-track">' + lane(h.needs, "needs") + lane(h.soon, "soon") + "</div></div>";
      else a += '<h2 class="j-label">' + (issueTab === "needs" ? "Needs you" : "Coming up") + "</h2>" + lane(issueTab === "needs" ? h.needs : h.soon, issueTab);
      if (h.snoozed) a += '<p class="j-snoozed sub">' + icon("moon") + " " + esc(h.snoozed) + "</p>";
      if (h.fineLine) a += '<div class="allgood j-good j-rise">' + U.ic("ok", "check-circle") + "<div><p>" + esc(h.fineLine) + '</p><p class="sub">Nothing to do there. Dokkit keeps watching.</p></div></div>';
    } else if (h.snoozed) a += '<p class="j-snoozed sub">' + icon("moon") + " " + esc(h.snoozed) + "</p>";

    var b = "", hw = h.hardware.filter(function (c) { return c.lastDay; });
    if (hw.length) {
      b += card('<div class="j-pad"><h2 class="j-h">The last day</h2><p class="j-hsub">The last 24 hours. Now is on the right.</p><div class="j-day-rows">' +
        hw.map(function (c, n) { return '<a href="#machine/' + esc(c.id) + '">' + esc(c.name) + "<span>" + icon("caret-right") + "</span></a>" + caps(c.id, false, n); }).join("") +
        '</div><div style="margin-top:14px">' + U.legend() + "</div></div>");
    }
    if (h.hardware.length) b += '<h2 class="j-label">Machines</h2>' + card('<div class="j-mlist">' + h.hardware.map(machineRow).join("") + "</div>");
    if (h.groups.length) b += '<h2 class="j-label">Not on a machine</h2>' + card('<div class="j-mlist">' + h.groups.map(machineRow).join("") + "</div>");
    return { tone: tone, attention: top.kind === "attention", firstNeed: h.needs[0] || h.soon[0] || null,
      top: hero({ tone: tone, icon: icn, eye: icon("hand-waving") + " " + esc(C.greeting()), big: big, lede: esc(lede), age: ageLine(f) }), a: a, b: b };
  }
  function homePage(part) {
    var p = homeParts();
    if (p.empty) return p.empty;
    if (part === "left") return { title: "Home", tools: true, tone: p.tone, top: p.top, body: p.a };
    if (part === "rest") return { title: "Machines", tools: false, tone: p.tone, body: '<div style="height:6px"></div>' + p.b };
    return { title: "Home", tools: true, tone: p.tone, top: p.top, body: p.a + p.b };
  }

  // ---------- service and machine ----------
  function service(id) {
    var s = C.selected(), snap = s && s.state.snapshot, f = s ? C.freshness(s.state) : null;
    if (!snap) return noSnapshot(f, "Service");
    var v = C.service(snap, id);
    if (!v) return { title: "Service", tone: "quiet", top: hero({ tone: "quiet", icon: "info", eye: "Service", big: "Not in this snapshot", lede: "The newest snapshot no longer lists this service." }), body: "" };
    var tone = v.level.tone;
    var line = [v.kind, v.version ? "version " + v.version : null, v.environment].filter(Boolean).join(" · ");
    var top = hero({ tone: tone, icon: v.level.icon, eye: U.tag(tone, v.level.word) + (v.machine ? ' <a href="#machine/' + esc(v.machine) + '">' + esc(v.machine) + "</a>" : ""),
      big: esc(v.name), lede: v.note ? esc(v.note) : "", extra: line ? '<p class="sub" style="margin-top:8px;font-size:12.5px">' + esc(line) + "</p>" : "", age: ageLine(f) });
    var b = f.warn || f.detail ? U.ageBanner(f) : "";
    var lo = C.leftOut(snap); if (lo) b += '<p class="sub j-left">' + icon("info") + " " + esc(lo) + "</p>";
    if (v.machine) b += '<a class="btn soft block" href="#machine/' + esc(v.machine) + '" style="min-height:46px;border-radius:14px">Open ' + esc(v.machine) + " " + icon("arrow-right") + "</a>";
    if (v.issue) {
      var i = v.issue, ist = C.issueState(i), lv = ist === "soon" ? C.LEVEL.soon : ist === "snoozed" ? C.LEVEL.snoozed : C.level(i.state);
      var meta = [C.names(snap)[i.service], i.machine, "Open since " + C.ago(i.since).replace(" ago", ""), i.count > 1 ? i.count + " times" : null].filter(Boolean);
      var fl = C.flags(i);
      b += card('<div class="j-chead"><span class="j-h">Open issue</span><span class="sub">' + esc(i.short_id) + "</span></div>" +
        '<div class="j-issue t-' + lv.tone + '"><p>' + U.tag(lv.tone, lv.word) + "</p><h3>" + esc(i.title) + "</h3>" + (i.note ? '<p class="say">' + esc(i.note) + "</p>" : "") +
        '<p class="meta">' + meta.map(esc).join(" · ") + "</p>" + (fl.length ? '<div class="j-flags">' + fl.map(function (x) { return U.tag(x.tone, x.text); }).join("") + "</div>" : "") + "</div>" +
        (v.history.length ? '<ol class="j-time">' + v.history.slice().reverse().map(function (e, n) {
          return '<li><span class="dot ' + (n === 0 ? "t-" + lv.tone : "t-quiet") + '" aria-hidden="true"></span><div><p>' + esc(e.text) + '</p><p class="sub">' + esc([e.ago, e.when].filter(Boolean).join(" · ")) + "</p></div></li>";
        }).join("") + "</ol>" : ""));
    }
    if (v.checks.length) {
      b += card('<div class="j-chead"><span class="j-h">Checks</span><span class="sub">' + v.checks.length + '</span></div><div style="padding-bottom:8px">' + v.checks.map(function (c) {
        return '<div class="j-check">' + U.ic(c.level.tone, c.level.icon, "sm") + '<div><p class="j-cname">' + esc(c.name) + '</p><p class="j-cstate t-' + c.level.tone + '">' + esc(c.level.word) + "</p>" +
          (c.note ? '<p class="sub">' + esc(c.note) + "</p>" : "") + (c.checked ? '<p class="sub">Checked ' + esc(c.checked) + "</p>" : "") + "</div></div>";
      }).join("") + "</div>");
    }
    if (v.job.length) b += card('<div class="j-chead"><span class="j-h">Job</span></div><dl class="j-dl">' + v.job.map(function (j) { return "<dt>" + esc(j[0]) + "</dt><dd>" + esc(j[1]) + "</dd>"; }).join("") + "</dl>");
    if (v.chart.some(function (x) { return x != null; })) {
      var present = v.chart.filter(function (x) { return x != null; });
      b += card('<div class="j-pad"><div style="display:flex;justify-content:space-between;align-items:baseline;gap:10px"><span class="j-h">Last 24 hours</span>' + (v.metric ? '<span class="sub">' + esc(v.metric) + "</span>" : "") + "</div>" +
        '<p style="margin:10px 0 0;font-size:34px;font-weight:800;letter-spacing:-.03em;font-variant-numeric:tabular-nums">' + num(Math.round(present[present.length - 1]), "chart-" + id) + '<span class="sub" style="font-size:14px;font-weight:600;margin-left:6px">now</span></p>' +
        U.chart(v.chart, v.metric) + '<div class="strip-axis"><span>24 h ago</span><span>Now</span></div></div>', "j-chart");
    }
    if (v.logs.length) b += card('<div class="j-chead"><span class="j-h">Last log lines</span><span class="sub">' + v.logs.length + '</span></div><div class="j-logs">' + U.logLines(v.logs) + "</div>");
    return { title: "Service", tools: true, tone: tone, top: top, body: b };
  }
  function machine(id) {
    var s = C.selected(), snap = s && s.state.snapshot, f = s ? C.freshness(s.state) : null;
    if (!snap) return noSnapshot(f, "Machine");
    var m = C.machineById(snap, id);
    if (!m) return { title: "Machine", tone: "quiet", top: hero({ tone: "quiet", icon: "info", eye: "Machine", big: "Not in this snapshot", lede: "The newest snapshot no longer lists this machine." }), body: "" };
    var c = C.card(m), tone = c.planned ? "quiet" : c.mark === "down" ? "down" : c.mark === "degraded" ? "degraded" : "ok";
    var mine = [].concat(snap.inbox.needs_you || [], snap.inbox.soon || [], snap.inbox.snoozed || []).filter(function (i) { return i.machine === id; });
    var lede = c.planned ? c.notice + ". That is expected, so Dokkit does not worry about it." : c.down ? "It has stopped reporting." : mine.length ? C.plural(mine.length, "thing needs", "things need") + " a look here." : "All good. " + c.counts + ".";
    var top = hero({ tone: tone, icon: c.planned ? "moon" : tone === "ok" ? "check-circle" : tone === "down" ? "warning-octagon" : "hourglass-medium",
      eye: (c.word ? U.tag(tone, c.word) : "") + (m.os ? " " + esc(m.os) : ""), big: esc(c.name), lede: esc(lede),
      extra: c.status ? '<p class="sub" style="margin-top:8px;font-size:12.5px">' + esc(c.status) + "</p>" : "", age: ageLine(f) });
    var b = f.warn || f.detail ? U.ageBanner(f) : "";
    if (c.meters.length) {
      b += card('<div class="j-vitals">' + c.meters.map(function (x, n) {
        return '<div class="j-vital' + (x.hot ? " hot" : "") + '"><span class="k">' + esc(x.label) + (x.subject ? " " + esc(x.subject) : "") + "</span><b>" + num(x.percent, "v-" + id + n) + "<small>%</small></b>" +
          '<div class="meter" role="meter" aria-label="' + esc(x.label) + '" aria-valuenow="' + x.percent + '" aria-valuemin="0" aria-valuemax="100"><b class="' + (x.hot ? "hot" : "") + '" style="width:' + x.percent + '%"></b></div></div>';
      }).join("") + "</div>");
    } else if (c.hardware) b += '<p class="sub j-line">' + (c.down ? "Not reporting, so no readings." : "No readings in this snapshot.") + "</p>";
    if (c.lastDay) b += card('<div class="j-pad"><span class="j-h">The last day</span><p class="j-hsub" style="margin-bottom:16px">The last 24 hours.</p>' + caps(c.id, true) +
      '<div class="strip-axis"><span>24 h ago</span><span>12 h ago</span><span>Now</span></div><div style="margin-top:12px">' + U.legend() + "</div></div>");
    if (mine.length) b += '<h2 class="j-label">Needs a look</h2><div class="d-lane">' + mine.map(function (i) { return '<div data-morph="' + esc(i.service) + '">' + U.issueCard(i, snap, "#service/" + i.service) + "</div>"; }).join("") + "</div>";
    b += '<h2 class="j-label">Services</h2>' + card('<div class="j-svcs pad-s">' + services(c) + "</div>");
    return { title: "Machine", tools: true, tone: tone, top: top, body: b };
  }

  // ---------- servers ----------
  function serversPage() {
    var list = C.servers(), cur = C.selected();
    if (!list.length) return { title: "Servers", tone: "quiet", top: hero({ tone: "quiet", icon: "device-mobile", eye: "Servers", big: "No server paired",
      lede: "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Choose Add a server below and scan it." }), body: '<a class="btn primary block" href="#add">' + icon("plus") + " Add a server</a>" };
    var f = C.freshness(cur.state);
    return { title: "Servers", tone: "brand", top: hero({ tone: "brand", icon: "hard-drives", eye: "Servers", big: num(list.length, "srv-n") + (list.length === 1 ? " server paired" : " servers paired"),
      lede: "Showing " + esc(cur.name) + ". Remove one and its key, token and saved snapshot leave this phone.", age: f.text }), body: U.serversList() };
  }
  function serverDetail() {
    var s = C.selected(); if (!s) return placeholder("hard-drives", "No server yet", "Add one on the left.");
    var f = C.freshness(s.state), snap = s.state.snapshot;
    var b = f.warn || f.detail ? U.ageBanner(f) : "";
    if (snap) {
      var h = C.home(snap), fine = snap.inbox.fine && snap.inbox.fine.services || 0;
      b += card('<div class="j-figs">' + figure(h.needs.length, "need you", "degraded", "sd-n-" + s.id) + figure(h.soon.length, "coming up", "soon", "sd-s-" + s.id) + figure(fine, "fine", "ok", "sd-f-" + s.id) + "</div>");
    }
    b += card('<dl class="d-facts"><dt>Relay</dt><dd>' + esc(C.host(s.relay)) + "</dd><dt>Paired</dt><dd>" + esc(C.short(s.added_at)) + "</dd><dt>Snapshot</dt><dd>" + esc(f.text) + "</dd></dl>");
    b += '<div class="d-acts"><a class="btn primary block" href="#home">' + icon("house") + " Show it on Home</a>" +
      '<button class="btn ghost block danger" type="button" data-remove="' + esc(s.id) + '">' + icon("trash") + " Remove from this phone</button></div>";
    return { title: s.name, tone: "brand", top: hero({ tone: "brand", icon: "hard-drives", eye: U.tag("brand", "Showing"), big: esc(s.name), lede: "Read-only. Nothing here can change the server.", age: ageLine(f) }), body: b };
  }
  function addPage(mode) {
    var paste = mode === "paste";
    return { title: "Add a server", back: true, backIcon: "x", backLabel: "Cancel", tone: "brand",
      top: hero({ tone: "brand", icon: paste ? "clipboard-text" : "qr-code", eye: "Add a server", big: paste ? "Paste the code" : "Scan the code",
        lede: paste ? "Paste the code from the Dokkit web interface, under Settings, Phones, Add a phone." : "Scan the QR code in the Dokkit web interface under Settings, Phones, Add a phone. It is shown once." }),
      body: '<div class="j-add">' + U.addServer(mode) + "</div>" };
  }

  // ---------- settings ----------
  function rows(keys) { return keys.map(function (k) { return U.settingRow(C.SETTINGS.find(function (s) { return s.key === k; })); }).join(""); }
  function saveRow() { return '<div class="save-row"><p class="sub">Applies on this phone only.</p><button class="btn primary" type="button" data-save style="min-width:120px">' + icon("check") + " Save</button></div>"; }
  function settingsHero() {
    var n = C.SETTINGS.filter(function (s) { return s.key !== "accent" && C.isChanged(s.key); }).length;
    return hero({ tone: "brand", icon: "sliders-horizontal", eye: "Settings", big: n ? num(n, "set-n") + " changed" : "All on defaults", lede: "Each starts at the value the app has always used, and shows it with a Reset next to it." });
  }
  function about() { return card('<div class="j-pad"><span class="j-h">About</span><p class="j-hsub" style="margin-top:6px">Dokkit for ' + (document.documentElement.dataset.device === "android" ? "Android" : "iPhone") + ' 0.1.0. Read-only: it cannot change anything on a server and sends no notifications. It fetches when opened, when you pull down, and on the schedule above while in front.</p></div>'); }
  function settingsFolds(openId) {
    return GROUPS.map(function (g, n) {
      return '<details class="panel fold" id="set-' + g[0] + '"' + ((openId ? g[0] === openId : n === 0) ? " open" : "") + "><summary>" + U.ic("brand", g[1], "sm") + '<div><span class="h2">' + g[2] + '</span><p class="sub">' + g[3] + "</p></div>" + icon("caret-down").replace('class="ph', 'class="chev ph') + "</summary>" +
        '<div class="fold-body">' + rows(g[4]) + saveRow() + "</div></details>";
    }).join("");
  }
  function settingsPage(openId) { return { title: "Settings", tone: "brand", top: settingsHero(), body: settingsFolds(openId) + about() }; }
  function settingsIndex(cur) {
    return { title: "Settings", tone: "brand", top: settingsHero(), body: card('<nav class="d-groups" aria-label="Settings groups">' + GROUPS.map(function (g) {
      return '<a href="#settings/' + g[0] + '"' + (g[0] === cur ? ' aria-current="page"' : "") + ">" + U.ic("brand", g[1], "sm") + '<div><span class="h2">' + g[2] + '</span><p class="sub">' + g[3] + "</p></div>" + icon("caret-right").replace('class="ph', 'class="chev ph') + "</a>";
    }).join("") + "</nav>") + about() };
  }
  function settingsGroup(id) {
    var g = GROUPS.find(function (x) { return x[0] === id; }) || GROUPS[0];
    return { title: g[2], tone: "brand", top: hero({ tone: "brand", icon: g[1], eye: "Settings", big: esc(g[2]), lede: esc(g[3]) }), body: card('<div class="d-rows">' + rows(g[4]) + saveRow() + "</div>") };
  }
  function aboutPage() {
    return { title: "About", tone: "quiet", top: hero({ tone: "quiet", icon: "info", eye: "About", big: "Dokkit", lede: "A read-only view of your Dokkit server. Alerts still reach you the usual way." }), body: about() };
  }

  // ---------- lock, first run, the quiet right side ----------
  function centerCard(tone, inner) { return '<div class="j-center j-settle"><section class="j-hero j-tone-' + tone + '">' + inner + "</section></div>"; }
  function lockPage() {
    var msg = C.scenario === "nolock" ? "Set a passcode on this phone to use Dokkit." : C.scenario === "stayed" ? "Dokkit stayed locked." : "Unlock with Touch ID or your passcode.";
    var tone = C.scenario === "nolock" || C.scenario === "stayed" ? "degraded" : "brand";
    return { tone: tone, raw: centerCard(tone, '<div class="j-hrow"><span class="j-hic" aria-hidden="true">' + icon("lock-simple") + '</span><p class="j-eye">Dokkit</p></div><h1 class="j-big">Dokkit is locked</h1><p class="j-lede">' + esc(msg) + "</p>" +
      '<button class="btn primary block" type="button" data-go="#home" style="min-height:52px;border-radius:16px;margin-top:18px">' + icon("fingerprint") + " Unlock</button>") };
  }
  function firstPage() {
    return { tone: "brand", raw: centerCard("brand", '<div class="j-mark">' + U.mark(64) + '</div><h1 class="j-big">Dokkit</h1><p class="j-lede">A read-only view of your Dokkit server. Alerts still reach you the usual way. Nothing here can change anything.</p>' +
      '<p class="sub" style="margin-top:12px">The code is in the Dokkit web interface: Settings, Phones, Add a phone.</p>' +
      '<div class="j-acts"><a class="btn primary block" href="#add" style="min-height:52px;border-radius:16px">' + icon("qr-code") + ' Scan the code</a><a class="btn ghost block" href="#add/paste">Paste the code instead</a></div>') };
  }
  function quietSide() { return { tone: "brand", raw: '<div class="quiet-side"><div>' + U.mark(56) + "<p>Read-only. Nothing here can change anything on a server.</p></div></div>" }; }
  function placeholder(ic, title, text) {
    return { tone: "quiet", raw: '<div class="ph-wrap"><div class="ph-card">' + U.ic("quiet", ic) + "<h2>" + esc(title) + "</h2><p>" + esc(text) + "</p></div></div>" };
  }

  // ---------- which page goes where ----------
  function foldedPage(r) {
    if (r.name === "lock") return lockPage();
    if (r.name === "first" || noServers() && r.name !== "add") return firstPage();
    if (r.name === "servers") return serversPage();
    if (r.name === "settings") return settingsPage(r.id);
    if (r.name === "add") { var a = addPage(r.id); if (noServers()) a.back = true; return a; }
    if (r.name === "service") return withBack(service(r.id));
    if (r.name === "machine") return withBack(machine(r.id));
    return homePage("full");
  }
  function withBack(p) { p.back = true; return p; }
  function leftPage(r) {
    if (r.name === "lock") return lockPage();
    if (r.name === "first" || noServers() && r.name !== "add") return firstPage();
    var t = tabOf(r);
    if (t === 1) return serversPage();
    if (t === 2) return DIR === "m" ? settingsPage() : settingsIndex(r.id || "look");
    if (DIR === "k") return homePage("left");
    if (DIR === "l") { var p = homeParts(); return p.empty || !p.attention ? homePage("left") : homePage("full"); }
    return homePage("full");
  }
  function leftKey(r) {
    if (r.name === "lock" || r.name === "first" || noServers() && r.name !== "add") return r.name === "lock" ? "lock" : "first";
    var t = tabOf(r);
    return t === 2 && DIR !== "m" ? "settings/" + (r.id || "look") : TABS[t][0];
  }
  function rightPage(r) {
    if (r.name === "lock" || r.name === "first" || noServers() && r.name !== "add") return quietSide();
    if (r.name === "service") return withBack(service(r.id));
    if (r.name === "machine") return withBack(machine(r.id));
    if (r.name === "add") return addPage(r.id);
    var t = tabOf(r);
    if (t === 1) return DIR === "m" ? placeholder("hard-drives", "Pick something on the left", "A server's details, or Add a server, open here.") : serverDetail();
    if (t === 2) return DIR === "m" ? aboutPage() : settingsGroup(r.id || "look");
    if (DIR === "m") return placeholder("hand-pointing", "Pick something on the left", "An issue, a machine or a service opens here, and the left side stays where it is.");
    var p = homeParts();
    if (p.empty) return placeholder("hourglass-medium", "Nothing to show yet", "The first snapshot fills this side.");
    if (DIR === "l" && p.attention && p.firstNeed) { var sp = service(p.firstNeed.service); sp.auto = true; return sp; }
    return homePage("rest");
  }
  function rightKey(r) {
    if (r.name === "service" || r.name === "machine" || r.name === "add") return r.hash;
    var t = tabOf(r);
    if (t === 2) return "settings/" + (DIR === "m" ? "about" : r.id || "look");
    if (t === 1) return "servers/" + (C.selected() ? C.selected().id : "");
    return r.name === "lock" || r.name === "first" ? "quiet" : "home";
  }

  // ---------- drawing a page into a host ----------
  function topbar(p, inPane) {
    var s = C.selected(), many = C.servers().length > 1, server = p.tools && s;
    return '<header class="j-top">' +
      (p.back ? '<button class="iconbtn" type="button" data-back aria-label="' + (p.backLabel || "Back") + '" style="margin-left:0">' + icon(p.backIcon || "arrow-left") + "</button>" : '<span class="j-top-gap"></span>') +
      '<div class="j-top-t" style="padding-left:' + (p.back ? 8 : 0) + 'px"><h1>' + esc(p.title || "") + "</h1>" + (server ? '<p class="sub">' + esc(s.name) + "</p>" : "") + "</div>" +
      (p.tools ? (many ? '<button class="iconbtn" type="button" data-picker aria-label="Switch server">' + icon("swap") + "</button>" : "") +
        '<button class="iconbtn" type="button" data-refresh aria-label="Refresh">' + icon("arrows-clockwise") + "</button>" : "") +
      "</header>";
  }
  function pageHTML(p, nav) {
    if (p.raw) return '<div class="pg j j-tone-' + p.tone + '"><div class="screen">' + p.raw + "</div></div>";
    return '<div class="pg j j-tone-' + p.tone + (nav ? " has-nav" : "") + '">' + topbar(p) + '<div class="screen">' + (p.top || "") + '<div class="j-body">' + p.body + "</div></div></div>";
  }
  // Puts a page into a host; slides it in on the travel spring when asked.
  function put(host, html, anim) {
    var old = host.querySelector(".slot:last-of-type"), oldScroll = old && old.querySelector(".screen") ? old.querySelector(".screen").scrollTop : 0;
    var slot = document.createElement("div");
    slot.className = "slot"; slot.innerHTML = html;
    host.appendChild(slot);
    wirePage(slot);
    if (!anim || !old || REDUCED) {
      if (old) { if (!anim && slot.querySelector(".screen")) { slot.querySelector(".screen").scrollTop = oldScroll; feedP(slot.querySelector(".screen")); } host.querySelectorAll(".slot").forEach(function (s) { if (s !== slot) s.remove(); }); }
      return slot;
    }
    var vertical = anim.axis === "y", size = vertical ? host.clientHeight : host.clientWidth, sign = anim.sign || 1, push = anim.push;
    var t = function (el, v) { el.style.transform = vertical ? "translateY(" + v + "px)" : "translateX(" + v + "px)"; };
    old.style.pointerEvents = "none";
    // A push slides the new page over the old; going back slides the old page off the new one.
    var under = push && sign < 0;
    if (under) old.style.zIndex = "2";
    run01(function (p) {
      if (!push) { t(slot, sign * size * (1 - p)); t(old, -sign * size * p); return; }
      if (under) { t(old, size * p); t(slot, -size * 0.3 * (1 - p)); slot.style.opacity = String(0.75 + 0.25 * p); }
      else { t(slot, size * (1 - p)); t(old, -size * 0.3 * p); old.style.opacity = String(1 - 0.25 * p); }
    }, function () { old.remove(); slot.style.transform = ""; slot.style.opacity = ""; });
    return slot;
  }

  // ---------- the app ----------
  var root, layout = null, hosts = {}, keys = {}, nav = null, navTab = 0, lastRoute = null, stack = [], popping = false, skipAnim = false;

  function build(mode) {
    layout = mode; keys = {}; hosts = {};
    var app = document.getElementById("app");
    app.innerHTML = '<div class="duo ' + mode + " dir-" + DIR + '" id="duo">' + statusbar() +
      (mode === "open"
        ? '<div class="stage"><section class="pane left"><div class="host" id="h-left"></div></section><section class="pane right"><div class="host" id="h-right"></div></section></div>'
        : '<div class="stage"><div class="host" id="h-main"></div></div>') +
      '<div class="navwrap" id="navwrap"></div><div class="toast" id="toast" role="status" aria-live="polite"></div><div id="layer"></div></div>';
    root = document.getElementById("duo");
    hosts.left = document.getElementById("h-left"); hosts.right = document.getElementById("h-right"); hosts.main = document.getElementById("h-main");
    nav = Glass({
      cls: mode === "open" && DIR === "m" ? "rail-gl" : "nav-gl", vertical: mode === "open" && DIR === "m", selected: Math.max(0, navTab),
      items: TABS.map(function (t) { return icon(t[2]) + "<span>" + t[1] + "</span>"; }),
      onSelect: function (i) { go("#" + TABS[i][0]); }
    });
    nav.setAttribute("aria-label", "Main");
    document.getElementById("navwrap").appendChild(nav);
  }
  function statusbar() {
    var t = new Date(C.P.now).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    return '<div class="statusbar" aria-hidden="true"><span>' + t + '</span><span class="icons">' + icon("wifi-high") + icon("cell-signal-full") + icon("battery-high") + "</span></div>";
  }

  function render(o) {
    o = o || {};
    var r = route(), mode = isOpen() ? "open" : "folded";
    if (mode !== layout) { build(mode); o.anim = null; }
    var tab = tabOf(r), prevTab = lastRoute ? tabOf(lastRoute) : tab;
    var tabMove = lastRoute && tab !== prevTab && tab >= 0 && prevTab >= 0 && !o.force;
    var tabAnim = tabMove ? (DIR === "m" && mode === "open" ? { axis: "y", sign: tab > prevTab ? 1 : -1 } : { axis: "x", sign: tab > prevTab ? 1 : -1 }) : null;
    var pageAnim = !o.force && !tabMove && lastRoute && lastRoute.hash !== r.hash && !skipAnim ? { axis: "x", sign: popping ? -1 : 1, push: true } : null;

    var showNav = tab >= 0 && !(mode === "folded" && r.name === "add");
    if (mode === "folded") {
      var fk = r.hash;
      if (o.force || keys.main !== fk) { put(hosts.main, pageHTML(foldedPage(r), showNav), tabAnim || pageAnim); keys.main = fk; }
    } else {
      var lk = leftKey(r), rk = rightKey(r);
      if (o.force || keys.left !== lk) { put(hosts.left, pageHTML(leftPage(r)), tabAnim); keys.left = lk; }
      if (o.force || keys.right !== rk) { put(hosts.right, pageHTML(rightPage(r)), tabAnim || (skipAnim ? null : pageAnim)); keys.right = rk; }
    }
    // Open, one background runs across both pages, in the tone of the left one.
    if (mode === "open") { var lp = hosts.left.querySelector(".slot:last-of-type .pg"); root.querySelector(".stage").className = "stage " + (lp ? lp.className.split(" ").filter(function (c) { return c.indexOf("j-tone-") === 0; }).join(" ") : ""); }
    document.getElementById("navwrap").style.display = showNav ? "" : "none";
    root.classList.toggle("nonav", !showNav);
    if (tab >= 0 && nav.glass.selected !== tab) nav.glass.select(tab, !!lastRoute && !o.force);
    navTab = tab;
    lastRoute = r; popping = false; skipAnim = false;
    afterAll();
  }

  function wirePage(slot) {
    slot.querySelectorAll(".screen").forEach(function (sc) {
      if (REDUCED) return;
      var queued = false;
      sc.addEventListener("scroll", function () { if (!queued) { queued = true; requestAnimationFrame(function () { queued = false; feedP(sc); }); } }, { passive: true });
    });
    slot.querySelectorAll("[data-seg]").forEach(function (holder) {
      var n = holder.dataset.seg.split("/"), track = holder.nextElementSibling.querySelector(".d-track"), clip = holder.nextElementSibling;
      var lanes = track.querySelectorAll(".d-lane"), sel = issueTab === "soon" ? 1 : 0;
      var g = Glass({ cls: "seg-gl", selected: sel, items: ["Needs you <small>" + n[0] + "</small>", "Coming up <small>" + n[1] + "</small>"],
        onSelect: function (i) { issueTab = i ? "soon" : "needs"; },
        onPos: function (x) {
          track.style.transform = "translateX(calc(" + (-x * 100) + "% - " + (x * 40) + "px))";
          var h0 = lanes[0].offsetHeight, h1 = lanes[1].offsetHeight;
          clip.style.height = (h0 + (h1 - h0) * Math.min(1, Math.max(0, x))) + "px";
        } });
      g.setAttribute("aria-label", "Show");
      holder.appendChild(g);
    });
  }
  function feedP(sc) { sc.style.setProperty("--p", Math.min(1, Math.max(0, sc.scrollTop / 240)).toFixed(3)); }

  function afterAll() {
    U.wire(function () { render({ force: true }); });
    root.querySelectorAll("[data-back]").forEach(function (b) { b.onclick = back; });
    root.querySelectorAll("[data-refresh]").forEach(function (b) { b.onclick = function () { refresh(b); }; });
    root.querySelectorAll("[data-picker]").forEach(function (b) { b.onclick = function () { picker(b); }; });
    root.querySelectorAll("[data-machine]").forEach(function (b) { b.onclick = function () { openMachines[b.dataset.machine] = !openMachines[b.dataset.machine]; render({ force: true }); }; });
    root.querySelectorAll("[data-more]").forEach(function (b) { b.onclick = function () { openMore[b.dataset.more] = !openMore[b.dataset.more]; render({ force: true }); }; });
    root.querySelectorAll("[data-morph]").forEach(function (el) {
      el.onclick = function (e) {
        if (e.target.closest("a") && !e.target.closest('a[href^="#service/"]')) return;
        e.preventDefault();
        openInto(el, "#service/" + el.dataset.morph);
      };
    });
    root.querySelectorAll("details.fold > summary").forEach(function (s) {
      s.onclick = function () { if (layout === "folded") { var d = s.parentNode; setTimeout(function () { if (d.open) here = "#settings/" + d.id.replace("set-", ""); }, 0); } };
    });
    growOnce(); tickOnce();
  }
  function growOnce() {
    root.querySelectorAll(".cap").forEach(function (c) {
      var key = (c.closest(".pane") ? c.closest(".pane").className : "main") + c.dataset.cap + (c.classList.contains("lg") ? "lg" : "");
      if (seen[key] || REDUCED) return; seen[key] = true; c.classList.add("grow");
    });
  }
  function tickOnce() {
    root.querySelectorAll(".j-num").forEach(function (el) {
      var key = el.dataset.key, to = +el.dataset.to;
      if (seen["n" + key] === to || REDUCED || !to) { seen["n" + key] = to; return; }
      var from = seen["n" + key] || 0; seen["n" + key] = to;
      var t0 = performance.now();
      (function step(t) { var k = Math.min(1, (t - t0) / 700), e = 1 - Math.pow(1 - k, 3); el.textContent = Math.round(from + (to - from) * e); if (k < 1) requestAnimationFrame(step); })(t0);
    });
  }

  // ---------- navigation ----------
  function back() {
    var r = route(), to = stack.length ? stack.pop() : "#" + TABS[Math.max(0, tabOf(r))][0];
    popping = true; ignoreNext = true;
    go(to);
  }
  var ignoreNext = false;
  function go(to) {
    if (to === here) { ignoreNext = false; popping = false; return; }
    var prev = here; here = to;
    var r = route(), pr = { name: prev.slice(1).split("/")[0] };
    if (ignoreNext) ignoreNext = false;
    else if (tabOf(r) !== tabOf(pr) || ["home", "servers", "settings"].indexOf(r.name) > -1) stack = [];
    else stack.push(prev);
    render();
    if (!popping) root.querySelectorAll(layout === "open" ? "#h-right .slot:last-of-type .screen" : "#h-main .slot:last-of-type .screen").forEach(function (s) { if (r.name === "service" || r.name === "machine" || r.name === "add") s.scrollTop = 0; });
  }
  // Links inside the app move it, not the page around it.
  document.addEventListener("click", function (e) {
    var a = e.target.closest('a[href^="#"]');
    if (!a || e.defaultPrevented) return;
    e.preventDefault();
    go(a.getAttribute("href"));
  });
  window.DEMO = { go: go };
  window.addEventListener("resize", function () { var m = isOpen() ? "open" : "folded"; if (m !== layout) render(); else if (nav) nav.glass.redraw(); });

  // An issue card opens into its page: the right pane when open, the whole screen when folded.
  function openInto(el, hash) {
    var target = layout === "open" ? hosts.right : hosts.main;
    if (REDUCED) { skipAnim = true; go(hash); return; }
    var rr = root.getBoundingClientRect(), from = el.getBoundingClientRect(), to = target.getBoundingClientRect();
    if (layout === "open") to = { left: to.left + 12, top: to.top, width: to.width - 12, height: to.height };
    var cardEl = el.querySelector(".issue") || el, fly = document.createElement("div");
    fly.className = "fly";
    var cs = getComputedStyle(cardEl);
    fly.style.background = cs.backgroundImage !== "none" ? cs.backgroundImage + "," + cs.backgroundColor : cs.backgroundColor;
    fly.style.overflow = "hidden";
    var copy = cardEl.cloneNode(true);
    copy.style.cssText = "width:" + from.width + "px;margin:0;box-shadow:none;border-color:transparent;background:none";
    fly.appendChild(copy);
    root.appendChild(fly);
    var f = { x: from.left - rr.left, y: from.top - rr.top, w: from.width, h: from.height }, t = { x: to.left - rr.left, y: to.top - rr.top, w: to.width, h: to.height };
    el.style.visibility = "hidden";
    run01(function (p) {
      fly.style.left = f.x + (t.x - f.x) * p + "px"; fly.style.top = f.y + (t.y - f.y) * p + "px";
      fly.style.width = f.w + (t.w - f.w) * p + "px"; fly.style.height = f.h + (t.h - f.h) * p + "px";
      fly.style.borderRadius = 24 - 24 * Math.min(1, p) + "px";
      copy.style.opacity = String(Math.max(0, 1 - p * 1.6));
    }, function () {
      skipAnim = true; go(hash);
      setTimeout(function () { el.style.visibility = ""; fly.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 220, fill: "forwards" }).onfinish = function () { fly.remove(); }; }, 30);
    });
  }

  // The refresh icon turns one lap at a time, only while a refresh is running.
  var refreshing = false;
  function refresh(b) {
    if (refreshing) return;
    refreshing = true;
    var ic = b.querySelector(".ph");
    (function lap() {
      if (!refreshing || REDUCED) return;
      ic.animate([{ transform: "rotate(0)" }, { transform: "rotate(360deg)" }], { duration: 800, easing: "linear" }).onfinish = lap;
    })();
    U.fakeRefresh(function () { refreshing = false; });
  }

  // The server picker grows out of its button into a window near the top of its pane, with a halo around just that window.
  function picker(btn) {
    var rr = root.getBoundingClientRect(), br = btn.getBoundingClientRect();
    var pane = btn.closest(".pane"), pr = pane ? pane.getBoundingClientRect() : rr;
    var inL = 12, inR = 12;
    if (pane && pane.classList.contains("left")) inR = 24;
    if (pane && pane.classList.contains("right")) inL = 24;
    if (pane && pane.classList.contains("left") && DIR === "m") inL = 96;
    var cur = C.selected();
    var scrim = document.createElement("div"); scrim.className = "pk-scrim";
    var pk = document.createElement("div"); pk.className = "pk"; pk.setAttribute("role", "dialog"); pk.setAttribute("aria-label", "Show a server");
    pk.innerHTML = '<div class="pk-in"><h2>Show a server</h2>' + C.servers().map(function (s) {
      var on = cur && s.id === cur.id;
      return '<button class="j-pick" type="button" data-pick="' + esc(s.id) + '"' + (on ? ' aria-current="true"' : "") + '><span><span class="srv-name">' + esc(s.name) + '</span><span class="sub">' + esc(C.host(s.relay)) + "</span></span>" + (on ? icon("check") : "") + "</button>";
    }).join("") + "</div>";
    var t = { x: pr.left - rr.left + inL, y: pr.top - rr.top + 72, w: pr.width - inL - inR };
    pk.style.cssText = "left:-9999px;top:0;width:" + t.w + "px;visibility:hidden";
    root.appendChild(scrim); root.appendChild(pk);
    t.h = pk.querySelector(".pk-in").offsetHeight;
    var f = { x: br.left - rr.left, y: br.top - rr.top, w: br.width, h: br.height };
    pk.style.visibility = "";
    var inner = pk.querySelector(".pk-in");
    inner.style.width = t.w + "px";
    btn.classList.add("hid");
    function frame(p) {
      pk.style.left = f.x + (t.x - f.x) * p + "px"; pk.style.top = f.y + (t.y - f.y) * p + "px";
      pk.style.width = Math.max(0, f.w + (t.w - f.w) * p) + "px"; pk.style.height = Math.max(0, f.h + (t.h - f.h) * p) + "px";
      pk.style.borderRadius = 22 + 6 * Math.min(1, p) + "px";
      pk.style.setProperty("--k", Math.max(0, Math.min(1, p)).toFixed(3));
      inner.style.opacity = String(Math.max(0, Math.min(1, (p - 0.45) / 0.4)));
    }
    frame(0);
    run01(frame);
    function close(after) {
      scrim.onclick = null;
      run01(function (p) { frame(1 - p); }, function () { pk.remove(); scrim.remove(); btn.classList.remove("hid"); if (after) after(); });
    }
    scrim.onclick = function () { close(); };
    pk.querySelectorAll("[data-pick]").forEach(function (b) {
      b.onclick = function () { var id = b.dataset.pick; close(function () { C.select(id); render({ force: true }); }); };
    });
  }

  render();
})();
