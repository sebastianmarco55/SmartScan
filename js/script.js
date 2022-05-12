window.addEventListener("scroll", function () {
  const header = document.querySelector("header");
  header.classList.toggle("sticky", window.scrollY > 0);
});

function hamburger() {
  const hamburger = document.querySelector(".hamburger");
  const navigation = document.querySelector(".navigation");
  const header = document.querySelector("header");
  hamburger.classList.toggle("active");
  navigation.classList.toggle("active");
  header.classList.toggle("active");
}

const parentContainer = document.querySelector(".read-more-container");

parentContainer.addEventListener("click", (event) => {
  const current = event.target;

  const isReadMoreBtn = current.className.includes("read-more-btn");

  if (!isReadMoreBtn) return;

  const currentText = event.target.parentNode.querySelector(".read-more-text");

  currentText.classList.toggle("read-more-text--show");

  current.textContent = current.textContent.includes("Read More")
    ? "Read Less..."
    : "Read More...";
});
