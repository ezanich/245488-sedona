var link = document.querySelector(".button-drop");
var popup = document.querySelector(".reservation");
var form = popup.querySelector("form");
var date_from = popup.querySelector("[name=check-in]");
var date_until = popup.querySelector("[name=check-out]");
var number_adults = popup.querySelector("[name=adults]");
var number_child = popup.querySelector("[name=children]");
var isStorageSupport = true;
var storage_adults = "";
var storage_child = "";
  
try {
    storage_adults = localStorage.getItem("number_adults");
    storage_child = localStorage.getItem("number_child");
} catch (err) {
    isStorageSupport = false;
}

link.addEventListener("click", function(evt) {
	evt.preventDefault();
	popup.classList.toggle("reservation-show");

	if (storage_adults) {
		number_adults.value = storage_adults;
	}

	if (storage_child) {
		number_child.value = storage_child;
	}
});

form.addEventListener("submit", function (evt) {
	if (!date_from.value || !date_until.value || !number_adults.value || !number_child.value) {
        evt.preventDefault();
        console.log("Заполните поля формы");
    } else {
    	if (isStorageSupport) {
        	localStorage.setItem("number_adults", number_adults.value);
        	localStorage.setItem("number_child", number_child.value);
        }
    }
});