"use strict";

(() => {
  const profileButton = document.getElementById(
    "open-profile-button"
  );

  const profileSection = document.getElementById(
    "profile-section"
  );

  if (!profileButton || !profileSection) {
    console.error("プロフィール画面が見つかりません。");
    return;
  }

  // 役職表示欄を作成
  const rolesBox = document.createElement("div");
  rolesBox.id = "profile-roles-box";

  const heading = document.createElement("h3");
  heading.textContent = "サークル内の役職";

  const rolesContainer = document.createElement("div");
  rolesContainer.id = "profile-roles";

  rolesBox.append(heading, rolesContainer);

  // 権限表示の直後に追加
  const privileges = document.getElementById(
    "profile-privileges"
  );

  const privilegesParagraph = privileges?.closest("p");

  if (privilegesParagraph) {
    privilegesParagraph.after(rolesBox);
  } else {
    profileSection.appendChild(rolesBox);
  }

  // 自分に割り当てられた役職を取得
  async function loadMyRoles() {
    rolesContainer.textContent = "読み込み中...";

    try {
      const { data, error } = await db.rpc(
        "my_circle_roles"
      );

      if (error) {
        throw error;
      }

      rolesContainer.replaceChildren();

      if (!data || data.length === 0) {
        rolesContainer.textContent = "役職なし";
        return;
      }

      for (const role of data) {
        const tag = document.createElement("span");

        tag.className = "profile-role-tag";
        tag.textContent = role.name;

        rolesContainer.appendChild(tag);
      }

    } catch (error) {
      rolesContainer.textContent =
        "役職の取得に失敗しました：" + error.message;

      console.error(error);
    }
  }

  // プロフィールを開いたら役職を更新
  profileButton.addEventListener(
    "click",
    loadMyRoles
  );

  // ログアウト時に表示を消す
  db.auth.onAuthStateChange(event => {
    if (event === "SIGNED_OUT") {
      rolesContainer.replaceChildren();
    }
  });
})();